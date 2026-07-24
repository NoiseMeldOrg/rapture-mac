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
/// The narrow *file* deletions — `TriageProcessor` draining a root `.txt` whose
/// full content was durably written into a verified Markdown note, and
/// `RelayProcessor` draining already-filed relay copies — go through
/// `coordinatedRemoveFile`, which refuses directories so `removeIfEmpty` stays
/// the only directory-delete primitive. That invariant — never delete what
/// hasn't been preserved — is shared by every caller.
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

    /// Outcome of `coordinatedRemoveFile`. `alreadyGone` counts as success for
    /// queue-draining callers: the goal state ("no file") holds regardless of
    /// who got there first.
    enum RemovalOutcome: Equatable, Sendable {
        case removed
        case alreadyGone
        case failed(String)
    }

    /// Remove a single *file* under an `NSFileCoordinator` deletion intent.
    ///
    /// The processors drain queue files that live (or can live) in iCloud
    /// containers — the relay always is one, and the destination may be iCloud
    /// Drive. An uncoordinated delete races the file provider: right after a
    /// wake-time materialization the daemon can still hold the file and the
    /// delete fails transiently (observed 2026-07-23 in the relay). The
    /// deletion intent serializes with the daemon instead of racing it.
    ///
    /// Blocks until the coordinator grants access, so call it off the main
    /// actor. Directories are refused — `removeIfEmpty` remains the app's only
    /// directory-delete primitive.
    static func coordinatedRemoveFile(at url: URL, fileManager: FileManager = .default) -> RemovalOutcome {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .alreadyGone
        }
        guard !isDirectory.boolValue else {
            log.error("coordinatedRemoveFile: refused directory \(url.lastPathComponent, privacy: .public)")
            return .failed("\(url.lastPathComponent) is a directory")
        }
        var coordinationError: NSError?
        var removalError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { actualURL in
            do {
                try fileManager.removeItem(at: actualURL)
            } catch {
                removalError = error as NSError
            }
        }
        if let error = coordinationError ?? removalError {
            // Vanishing between the guard above and the accessor is the very race
            // this primitive exists for; "already gone" is the goal state.
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError {
                return .alreadyGone
            }
            return .failed(error.localizedDescription)
        }
        return .removed
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
