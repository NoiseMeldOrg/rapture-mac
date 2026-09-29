import Foundation

/// Where an error surfaced by the menu bar came from. Each source keeps its own
/// record, so a success in one part of the app clears only that part's error:
/// an iMessage capture filing fine must not hide a stuck relay file or a failed
/// reply (the pre-1.0.126 single `lastError` string did exactly that).
enum ErrorSource: String, Codable, Sendable, CaseIterable {
    case capture
    case attachments
    case relay
    case triage
    case queue
    case reply
    case folder
    case messagesDatabase
    case ai
}

/// One unresolved error, persisted in `state.json` so it survives a relaunch
/// with its real timestamp.
struct ErrorRecord: Codable, Sendable, Equatable {
    var source: ErrorSource
    var message: String
    var at: Date
}
