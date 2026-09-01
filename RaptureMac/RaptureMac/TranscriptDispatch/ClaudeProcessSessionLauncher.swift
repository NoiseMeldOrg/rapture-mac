import Foundation
import OSLog

/// Spawns one headless Claude Code session: `claude -p <prompt>` with the
/// agentic repo as the working directory. `claude` resolves via the captured
/// login-shell PATH (`/usr/bin/env` + `IntegrationRunner.mergeEnv`), because
/// the .app process inherits a minimal PATH.
///
/// Deliberately fire-and-observe, not run-to-completion: `launch()` returns as
/// soon as the child is running, and `TranscriptDispatchService` polls
/// `isRunning()` / the note marker. Nothing here calls `waitUntilExit()` (the
/// IntegrationRunner hang lesson) — after the child dies, `terminationStatus`
/// is read directly. stdout is discarded to the null device (no pipe, no
/// >64KB pipe-buffer deadlock); stderr is drained in the background for
/// failure forensics.
@MainActor
final class ClaudeProcessSessionLauncher: TranscriptSessionLaunching {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "ClaudeProcessSessionLauncher")

    /// How much stderr tail to surface in a failure message.
    nonisolated static let failureDetailLimit = 300

    private let loginPath: String
    private var process: Process?
    private var stderrBox: StderrBox?

    init(loginPath: String) {
        self.loginPath = loginPath
    }

    func launch(prompt: String, workingDirectory: URL) async throws {
        // The unit-test bundle is hosted inside Rapture.app; the suite must
        // never spawn a real `claude`. See ProcessInfo.isRunningXCTests.
        guard !ProcessInfo.processInfo.isRunningXCTests else {
            throw TranscriptSessionError.unavailableUnderTests
        }
        if let live = process, live.isRunning {
            throw TranscriptSessionError.spawnFailed("a session is already running")
        }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = ["claude", "-p", prompt, "--permission-mode", "bypassPermissions"]
        child.currentDirectoryURL = workingDirectory
        child.environment = IntegrationRunner.mergeEnv(loginPath: loginPath, overlay: [:])
        // Instant EOF on stdin — a headless child must never wait for input.
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice

        let stderrPipe = Pipe()
        child.standardError = stderrPipe
        let box = StderrBox()
        DispatchQueue.global(qos: .utility).async {
            box.data = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
            try? stderrPipe.fileHandleForReading.close()
        }

        do {
            try child.run()
        } catch {
            try? stderrPipe.fileHandleForWriting.close()
            Self.log.error("failed to spawn claude: \(error.localizedDescription, privacy: .public)")
            throw TranscriptSessionError.spawnFailed(error.localizedDescription)
        }
        process = child
        stderrBox = box
    }

    func isRunning() -> Bool {
        process?.isRunning ?? false
    }

    func terminate() {
        guard let live = process, live.isRunning else { return }
        live.terminate()
    }

    func lastFailureDetail() -> String? {
        guard let child = process, !child.isRunning else { return nil }
        let stderr = String(decoding: stderrBox?.data ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = String(stderr.suffix(Self.failureDetailLimit))
        if tail.isEmpty {
            return "claude exited with status \(child.terminationStatus)."
        }
        return "claude exited with status \(child.terminationStatus): \(tail)"
    }
}

/// Hands the drained stderr bytes from the background read to `lastFailureDetail`.
/// Written by exactly one utility-queue closure; read only after the child has
/// exited (EOF happens-before the read observes `isRunning == false` in
/// practice, and a torn read here at worst shortens a diagnostic string).
private final class StderrBox: @unchecked Sendable {
    var data = Data()
}
