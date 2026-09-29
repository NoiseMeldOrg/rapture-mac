import Foundation

/// Which half of a meeting a relay file carries (see `MeetingMarker`).
enum MeetingPart: String, Codable, Sendable, Equatable {
    case transcript
    case summary
}

/// One filed meeting, persisted in `state.json` and keyed by the iOS recording
/// id, so both parts of a meeting (and every re-made summary) land in the same
/// note. See `MeetingLedger`.
struct MeetingEntry: Codable, Sendable, Equatable {
    let meetingId: String
    /// Destination-relative path of the meeting's note, as last written.
    var noteRelativePath: String
    /// The part whose body the note holds now.
    var part: MeetingPart
    /// Every relay filename seen for this meeting. Lets late-arriving relay
    /// audio (paired by name with the transcript part) find its note.
    var relayFilenames: [String]
    /// Content hashes of the summary files already applied, newest last. A
    /// summary whose bytes match one here is an iCloud re-sync, not a new
    /// summary, and must never roll the note back to older text.
    var appliedSummaryHashes: [String]
    var updatedAt: Date
}
