import Foundation

/// Transient status of the triage engine (watcher + processor). Not persisted.
enum TriageStatus: Equatable, Sendable {
    /// Raw mode: the engine is idle by user choice.
    case off
    /// No output folder configured yet.
    case waitingForFolder
    /// Watching the destination root for external `.txt` arrivals.
    case watching
    /// `.icloud` placeholders at the root are being nudged to download.
    case waitingForDownload(count: Int)
    /// A backlog drain is in progress.
    case triaging(done: Int, total: Int)
}
