import Foundation

struct CaptureHashEntry: Codable, Sendable, Equatable {
    let handleNormalized: String
    let normalizedText: String
    let attachmentCount: Int
    let expiresAt: Date
}
