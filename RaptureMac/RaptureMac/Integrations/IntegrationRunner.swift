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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RunResult, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptURL.path]
            process.environment = mergeEnv(loginPath: loginPath, overlay: env)

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Two accumulators drained concurrently via readabilityHandler on
            // each pipe's background queue. Avoids the classic pipe-buffer
            // deadlock on scripts with >64KB of output to either stream.
            let outBuffer = Accumulator()
            let errBuffer = Accumulator()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { outBuffer.append(chunk) }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { errBuffer.append(chunk) }
            }

            process.terminationHandler = { p in
                // Detach handlers and drain any final buffered bytes.
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                if let remaining = try? stdoutPipe.fileHandleForReading.readToEnd() {
                    outBuffer.append(remaining)
                }
                if let remaining = try? stderrPipe.fileHandleForReading.readToEnd() {
                    errBuffer.append(remaining)
                }

                let result = RunResult(
                    exitCode: p.terminationStatus,
                    stdout: String(data: outBuffer.snapshot(), encoding: .utf8) ?? "",
                    stderr: String(data: errBuffer.snapshot(), encoding: .utf8) ?? ""
                )
                continuation.resume(returning: result)
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                process.terminationHandler = nil
                log.error("Failed to spawn \(scriptURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continuation.resume(throwing: error)
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

/// Lock-protected Data accumulator used by IntegrationRunner's pipe readabilityHandlers,
/// which fire on a background dispatch queue and need a Sendable accumulator that's safe
/// across the producer (handler) → consumer (terminationHandler) handoff.
private final class Accumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
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
