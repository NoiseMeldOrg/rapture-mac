import Foundation
import OSLog

struct AppleScriptSendError: Error, Sendable {
    let exitCode: Int32
    let stderr: String

    var isPermissionDenied: Bool {
        let lower = stderr.lowercased()
        if lower.contains("-1743") { return true }
        if lower.contains("not authorized to send apple events") { return true }
        if lower.contains("not allowed to send apple events") { return true }
        if lower.contains("not authorised to send apple events") { return true }
        if lower.contains("user has declined") { return true }
        return false
    }

    var userFacingMessage: String {
        let firstLine = stderr
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? ""
        return firstLine.isEmpty ? "AppleScript exited with code \(exitCode)" : firstLine
    }
}

protocol AppleScriptSending: Sendable {
    func send(text: String, toChatGuid chatGuid: String) async throws
}

final class AppleScriptSender: AppleScriptSending {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "AppleScriptSender")

    nonisolated static let script = """
        on run argv
            tell application "Messages" to send (item 1 of argv) to chat id (item 2 of argv)
        end run
        """

    nonisolated static let osascriptPath = "/usr/bin/osascript"

    nonisolated func send(text: String, toChatGuid chatGuid: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            try Self.runOsascript(text: text, chatGuid: chatGuid)
        }.value
    }

    nonisolated private static func runOsascript(text: String, chatGuid: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: osascriptPath)
        process.arguments = ["-", text, chatGuid]

        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        try process.run()

        let scriptData = Data(script.utf8)
        try stdinPipe.fileHandleForWriting.write(contentsOf: scriptData)
        try stdinPipe.fileHandleForWriting.close()

        process.waitUntilExit()

        let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        let stderrString = String(data: stderrData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            log.error("osascript exit=\(process.terminationStatus, privacy: .public) stderr=\(stderrString, privacy: .public)")
            throw AppleScriptSendError(exitCode: process.terminationStatus, stderr: stderrString)
        }
    }
}
