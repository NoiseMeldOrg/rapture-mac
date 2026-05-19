import Foundation

struct EchoEntry: Codable, Sendable, Equatable {
    let chatGuid: String
    let normalizedText: String
    let expiresAt: Date
}
