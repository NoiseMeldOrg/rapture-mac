import Foundation

enum ReplyMode: String, Codable, CaseIterable, Sendable {
    case all
    case errorsOnly
    case off
}
