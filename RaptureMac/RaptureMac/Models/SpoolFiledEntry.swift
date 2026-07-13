import Foundation

/// One flushed spool item, persisted in `state.json` so a crash between "note
/// filed at the destination" and "spool item removed" resumes as delete-only,
/// never a duplicate note. Keyed by the spool item's directory name, which is
/// unique forever (the seq component is monotonic and never reused). See
/// `SpoolFiledLedger`.
struct SpoolFiledEntry: Codable, Sendable, Equatable {
    let itemName: String
    let filedAt: Date
}
