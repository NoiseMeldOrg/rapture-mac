import Foundation

/// An iMessage note filed while some of its attachments had not downloaded
/// yet. Persisted in `state.json` so `AttachmentRetrier` keeps trying after a
/// quit or restart instead of forgetting.
struct PendingAttachmentRetry: Codable, Sendable, Equatable {
    /// Absolute path of the filed note.
    var notePath: String
    var attachments: [AttachmentRef]
    /// When the note filed; retry times count from here.
    var firstAt: Date
}
