import Foundation
import OSLog

/// Mirrors the current output-folder absolute path to a plain-text sidecar at
/// `~/Library/Application Support/Rapture for Mac/output-folder.path`.
///
/// This is the public contract for downstream consumers (Claude Code SessionStart hook,
/// OpenClaw / Hermes skills, custom scripts): they read this file to find where notes
/// land and re-read it to pick up folder changes, without needing to know anything about
/// how Rapture stores its settings. Rewritten atomically on every output-folder change
/// and on first-launch default initialization.
enum OutputFolderSidecar {
    static let fileName = "output-folder.path"
    private static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "OutputFolderSidecar")

    static func fileURL() throws -> URL {
        try AppSupportDirectory.url().appendingPathComponent(fileName)
    }

    /// The resolved absolute path string written into the sidecar for `url` (no trailing newline).
    static func contents(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
    }

    /// Atomically write the resolved absolute path of `url` (no trailing newline) to the sidecar.
    static func write(_ url: URL) {
        do {
            try write(url, to: try fileURL())
        } catch {
            log.error("Failed to write output-folder sidecar: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Testable overload: write the sidecar contents to an explicit destination.
    static func write(_ url: URL, to destination: URL) throws {
        try AtomicFile.write(Data(contents(for: url).utf8), to: destination)
    }
}
