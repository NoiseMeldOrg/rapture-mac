import XCTest
@testable import RaptureMac

final class IntegrationRunnerTests: XCTestCase {

    private var tempDir: URL!
    private var runner: IntegrationRunner!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntegrationRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        tempDir = base
        runner = IntegrationRunner(loginPath: "/usr/bin:/bin")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    @discardableResult
    private func writeScript(_ name: String, body: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try body.data(using: .utf8)!.write(to: url, options: .atomic)
        // Exec bit isn't required because IntegrationRunner invokes via /bin/bash.
        return url
    }

    // MARK: - Stdout / stderr / exit-code capture

    func testCapturesStdoutAndZeroExit() async throws {
        let script = try writeScript("stdout.sh", body: "#!/bin/bash\necho hello-world\n")
        let result = try await runner.run(script)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "hello-world\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertTrue(result.succeeded)
    }

    func testCapturesStderr() async throws {
        let script = try writeScript("stderr.sh", body: "#!/bin/bash\necho >&2 bad-thing\n")
        let result = try await runner.run(script)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "bad-thing\n")
        XCTAssertEqual(result.stdout, "")
    }

    func testCapturesNonZeroExit() async throws {
        let script = try writeScript("fail.sh", body: "#!/bin/bash\necho >&2 oops\nexit 7\n")
        let result = try await runner.run(script)
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.stderr, "oops\n")
    }

    func testCapturesBothStreams() async throws {
        let script = try writeScript("both.sh", body: """
        #!/bin/bash
        echo to-stdout
        echo to-stderr >&2
        """)
        let result = try await runner.run(script)
        XCTAssertEqual(result.stdout, "to-stdout\n")
        XCTAssertEqual(result.stderr, "to-stderr\n")
    }

    // MARK: - Env var overlay

    func testEnvVarOverlayIsPassedToScript() async throws {
        let script = try writeScript("envcheck.sh", body: """
        #!/bin/bash
        echo "WORKDIR=$RAPTURE_CLAUDE_WORKDIR"
        echo "MODEL=$RAPTURE_MEDIA_MODEL"
        """)
        let result = try await runner.run(script, env: [
            "RAPTURE_CLAUDE_WORKDIR": "/Users/me/Source/x",
            "RAPTURE_MEDIA_MODEL": "sonnet"
        ])
        XCTAssertEqual(result.stdout, "WORKDIR=/Users/me/Source/x\nMODEL=sonnet\n")
    }

    func testLoginPathIsUsedAsPathEnvVar() async throws {
        let customPath = "/tmp/fake-bin:/usr/bin:/bin"
        runner = IntegrationRunner(loginPath: customPath)
        let script = try writeScript("pathcheck.sh", body: "#!/bin/bash\necho \"$PATH\"\n")
        let result = try await runner.run(script)
        XCTAssertEqual(result.stdout, customPath + "\n")
    }

    func testOverlayDoesNotClobberOtherInheritedEnv() async throws {
        // HOME comes from ProcessInfo; verify overlay doesn't blow it away.
        let script = try writeScript("home.sh", body: "#!/bin/bash\necho \"$HOME\"\n")
        let result = try await runner.run(script, env: ["RAPTURE_FOO": "bar"])
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                       ProcessInfo.processInfo.environment["HOME"])
    }

    // MARK: - Deadlock prevention: large output

    func testLargeStdoutOutputDoesNotDeadlock() async throws {
        // 128KB of stdout — well past the 64KB pipe buffer that would deadlock
        // if we read stderr before stdout.
        let script = try writeScript("big.sh", body: """
        #!/bin/bash
        head -c 131072 /dev/urandom | base64
        """)
        let result = try await runner.run(script)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertGreaterThan(result.stdout.count, 100_000)
    }

    func testLargeStderrOutputDoesNotDeadlock() async throws {
        let script = try writeScript("big-err.sh", body: """
        #!/bin/bash
        head -c 131072 /dev/urandom | base64 >&2
        """)
        let result = try await runner.run(script)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertGreaterThan(result.stderr.count, 100_000)
    }

    func testLargeOutputOnBothStreamsDoesNotDeadlock() async throws {
        let script = try writeScript("big-both.sh", body: """
        #!/bin/bash
        head -c 100000 /dev/urandom | base64 &
        head -c 100000 /dev/urandom | base64 >&2 &
        wait
        """)
        let result = try await runner.run(script)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertGreaterThan(result.stdout.count, 50_000)
        XCTAssertGreaterThan(result.stderr.count, 50_000)
    }

    // MARK: - Spawn failure

    func testThrowsWhenScriptDoesNotExist() async throws {
        let nonexistent = tempDir.appendingPathComponent("missing.sh")
        do {
            _ = try await runner.run(nonexistent)
            // /bin/bash will run, then itself fail to find the script.
            // Result will have non-zero exit and a "No such file" stderr —
            // not a thrown error. Adjust the assertion accordingly.
        } catch {
            // /bin/bash always spawns successfully; we expect no throw.
            // If this changes, the test will fail loudly.
            XCTFail("Did not expect a throw — bash always spawns, then fails to find the script. Got: \(error)")
        }
        let result = try await runner.run(nonexistent)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.contains("No such file") || result.stderr.contains("cannot"))
    }

    // MARK: - mergeEnv helper

    func testMergeEnvSetsPath() {
        let env = IntegrationRunner.mergeEnv(loginPath: "/x:/y", overlay: [:])
        XCTAssertEqual(env["PATH"], "/x:/y")
    }

    func testMergeEnvOverlayWinsOnCollision() {
        let env = IntegrationRunner.mergeEnv(loginPath: "/from-login", overlay: ["PATH": "/from-overlay"])
        XCTAssertEqual(env["PATH"], "/from-overlay")
    }

    func testMergeEnvPreservesInheritedKeys() {
        let env = IntegrationRunner.mergeEnv(loginPath: "/x", overlay: [:])
        XCTAssertEqual(env["HOME"], ProcessInfo.processInfo.environment["HOME"])
    }

    // MARK: - LoginShellPath
    //
    // No automated test. LoginShellPath.capture() spawns `/bin/zsh -ilc 'echo $PATH'`
    // — the `-i` flag makes zsh interactive, which sources the user's .zshrc /
    // .zprofile. When the test runner (xctest, not Terminal.app) does that and the
    // shell init touches a TCC-protected resource, macOS prompts the runner for
    // permission — and the test stalls waiting for human dismissal. The function
    // is exercised manually at app launch and has a documented fallback path
    // (ProcessInfo.processInfo.environment["PATH"] → "/usr/bin:/bin"), so the
    // production code is covered without a test that destabilizes the suite.
}
