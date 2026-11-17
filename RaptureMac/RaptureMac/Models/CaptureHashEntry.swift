import Foundation

struct CaptureHashEntry: Codable, Sendable, Equatable {
    let handleNormalized: String
    let normalizedText: String
    let attachmentCount: Int
    let expiresAt: Date
    /// When the message was sent (`MessageEvent.dateUTC`). `ContentDedupCache`
    /// uses it to tell an iCloud replay (same send time) from a new note with
    /// the same words (new send time). Absent on entries written before send
    /// times were stored; those decode as `nil`.
    let sentAt: Date?
}
