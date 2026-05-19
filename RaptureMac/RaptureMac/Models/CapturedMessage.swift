import Foundation

struct CapturedMessage: Sendable {
    let event: MessageEvent
    let decodedText: String
    let isCatchup: Bool
}
