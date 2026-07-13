import Foundation

/// One triaged capture, persisted in `state.json`. Keyed by source filename plus a
/// content hash: timestamped filenames make a same-name re-arrival an iCloud/sync
/// ghost (drain silently), while the hash keeps a genuinely different same-named
/// hand-drop triagable. `mdRelativePath` records where the note landed relative to
/// the destination root — it makes ledger-hit draining safe (only drain the source
/// while the note still exists) and lets late-arriving relay audio land next to its
/// note. See `TriageLedger`.
struct TriagedEntry: Codable, Sendable, Equatable {
    let sourceFilename: String
    let contentHash: String
    let mdRelativePath: String
    let triagedAt: Date
}
