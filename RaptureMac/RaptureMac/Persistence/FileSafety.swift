import Foundation
import OSLog

/// Centralized, guarded filesystem primitives for output-folder safety.
///
/// The output folder holds the user's only copy of their notes, so the dangerous
/// directory operation — removal — is funneled through here. No path in the app
/// deletes the output folder or a subfolder of it except via `removeIfEmpty`,
/// which makes "delete a directory that still holds data" unreachable by
/// construction.
///
/// One narrow *file* deletion exists outside this funnel: `TriageProcessor`
/// removes a root `.txt` capture, and only after its full content was durably
/// written into a Markdown note verified present in the same operation (a ledger
/// hit likewise drains its source only while the recorded note still exists).
/// That invariant — never delete what hasn't been preserved — is the triage
/// engine's version of this file's guarantee.
enum FileSafety {
    static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "FileSafety")

    /// Remove `url` only when it is an *empty* directory. A directory that still holds
    /// anything — including a single dotfile — is left fully intact. Never throws:
    /// a non-empty directory is a deliberate no-op, and a failed removal of a
    /// verified-empty directory is logged and ignored.
    ///
    /// Returns `true` only when an empty directory was actually removed.
    @discardableResult
    static func removeIfEmpty(_ url: URL, fileManager: FileManager = .default) -> Bool {
        // `contentsOfDirectory` with empty options lists hidden/dotfiles too (it omits
        // only "." and ".."), so a folder holding only a dotfile reads as non-empty.
        guard let contents = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            // Missing, or not a readable directory (e.g. a file): nothing to remove.
            return false
        }
        guard contents.isEmpty else {
            log.debug("removeIfEmpty: \(url.lastPathComponent, privacy: .public) holds \(contents.count) item(s); left intact")
            return false
        }
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            log.error("removeIfEmpty: failed to remove empty \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// True when `url` is a directory that contains no entries (dotfiles counted).
    /// A missing path or a file returns `false`.
    static func isEmptyDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return false
        }
        return contents.isEmpty
    }
}
