import Foundation
import OSLog

/// Captured outcome of a script invocation. Non-zero exit is not an error —
/// callers (e.g. an Install button handler) want to display the stderr to the
/// user instead.
struct RunResult: Equatable, Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }
}

protocol IntegrationRunning: Sendable {
    func run(_ scriptURL: URL, env: [String: String]) async throws -> RunResult
}

/// Shells out to a bundled Scripts/*.sh via `/bin/bash <path>`. Mirrors the
/// AppleScriptSender pattern: nonisolated final class, async via Task.detached,
/// custom Sendable error from `process.run()` failures only — captured exit
/// codes are surfaced inside `RunResult`, not thrown.
///
/// `loginPath` is captured at construction (see `LoginShellPath.capture()`)
/// and used as the PATH env var for every script run, so scripts can find
/// `claude`, `jq`, `fswatch` from `/opt/homebrew/bin` etc. even though the
/// .app process inherits a minimal PATH.
final class IntegrationRunner: IntegrationRunning {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "IntegrationRunner")

    nonisolated private let loginPath: String

    init(loginPath: String) {
        self.loginPath = loginPath
    }

    nonisolated func run(_ scriptURL: URL, env: [String: String] = [:]) async throws -> RunResult {
        let path = self.loginPath
        return try await Self.runScript(scriptURL: scriptURL, env: env, loginPath: path)
    }

    nonisolated private static func runScript(
        scriptURL: URL,
        env: [String: String],
        loginPath: String
    ) async throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.environment = mergeEnv(loginPath: loginPath, overlay: env)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Three pieces of work must all finish before we have a result: draining each pipe
        // to EOF, and learning the exit code. We gather them with a DispatchGroup.
        //
        // The exit code comes from `terminationHandler`, NOT `process.waitUntilExit()`.
        // waitUntilExit() spins the *calling* thread's runloop waiting for the termination
        // event, but Foundation delivers that event on its own management thread — so calling
        // it from a GCD worker (no serviced runloop) hangs intermittently under load. That
        // exact hang reddened CI: ~1 spawn in ~120 wedged for the full test-timeout. The
        // terminationHandler fires reliably on Foundation's side once the child is reaped, so
        // nothing waits on a foreign thread. Draining the pipes with independent full reads
        // (rather than racing a readabilityHandler against a terminationHandler that also
        // reads, as an earlier version did) is what keeps the *output* capture reliable, and
        // avoids the >64KB pipe-buffer deadlock.
        let queue = DispatchQueue(label: "noisemeld.RaptureMac.IntegrationRunner.read", attributes: .concurrent)
        let group = DispatchGroup()
        let outBox = DataBox()
        let errBox = DataBox()
        let statusBox = ExitStatusBox()

        // Register all three group members BEFORE run(), so a child that exits instantly can't
        // empty the group (firing notify early) before the readers are in it.
        group.enter()
        process.terminationHandler = { p in
            statusBox.code = p.terminationStatus
            p.terminationHandler = nil
            group.leave()
        }
        queue.async(group: group) {
            outBox.data = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
            try? stdoutPipe.fileHandleForReading.close()
        }
        queue.async(group: group) {
            errBox.data = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
            try? stderrPipe.fileHandleForReading.close()
        }

        do {
            try process.run()
        } catch {
            // The child never launched, so terminationHandler won't fire. Balance its
            // group.enter() and close the write ends so the two readers see EOF and finish.
            process.terminationHandler = nil
            group.leave()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            log.error("Failed to spawn \(scriptURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }

        return await withCheckedContinuation { continuation in
            // Fires once both pipes hit EOF and the child has been reaped; the group orders
            // those writes happens-before this read, so the boxes are safe to read here.
            group.notify(queue: queue) {
                continuation.resume(returning: RunResult(
                    exitCode: statusBox.code,
                    stdout: String(decoding: outBox.data, as: UTF8.self),
                    stderr: String(decoding: errBox.data, as: UTF8.self)
                ))
            }
        }
    }

    /// Builds the env dict: starts from the parent process env, sets PATH
    /// from the captured login shell, then overlays caller-provided keys.
    /// Caller-supplied env values win over PATH if they collide (rare).
    nonisolated static func mergeEnv(loginPath: String, overlay: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = loginPath
        for (k, v) in overlay {
            env[k] = v
        }
        return env
    }
}

/// Minimal box handing a pipe's captured bytes from the background read closure to the
/// completion closure. Access is serialized by the `DispatchGroup` (each box is written by
/// exactly one read closure and read only after `group.notify`), so `@unchecked` is safe.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// Box handing the child's exit code from `terminationHandler` to the completion closure.
/// Written exactly once (in the handler, before its `group.leave()`) and read only after
/// `group.notify`, so the group's ordering makes `@unchecked` safe. The `-1` default is a
/// never-observed placeholder: on the success path the handler always runs before notify.
private final class ExitStatusBox: @unchecked Sendable {
    var code: Int32 = -1
}

/// One-shot helper that runs `/bin/zsh -ilc 'echo $PATH'` to capture the user's
/// interactive-shell PATH. Called once at app launch; result is cached and
/// passed to the IntegrationRunner constructor.
enum LoginShellPath {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "LoginShellPath")

    /// Captures the login-shell PATH. On failure, returns a sensible fallback
    /// (`ProcessInfo.processInfo.environment["PATH"]` if present, else
    /// `/usr/bin:/bin`). Never throws — login-shell discovery should be best-
    /// effort, not blocking app launch.
    nonisolated static func capture() -> String {
        // Skip the interactive-shell spawn in the XCTest host. `/bin/zsh -ilc` sources the
        // user's .zshrc/.zprofile; when shell init touches a TCC-protected resource the test
        // runner gets prompted and the suite stalls (this is also why there's no LoginShellPath
        // unit test). The fallback PATH is fine for tests — IntegrationRunnerTests construct
        // their own runner with an explicit loginPath. See ProcessInfo.isRunningXCTests.
        if ProcessInfo.processInfo.isRunningXCTests { return fallback() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ilc", "echo $PATH"]

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()  // discard shell-init chatter

        do {
            try process.run()
        } catch {
            log.error("Failed to spawn /bin/zsh: \(error.localizedDescription, privacy: .public)")
            return fallback()
        }

        let data = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()

        let captured = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return captured.isEmpty ? fallback() : captured
    }

    private nonisolated static func fallback() -> String {
        ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    }
}
