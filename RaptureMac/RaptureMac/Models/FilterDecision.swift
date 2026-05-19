import Foundation

enum DropReason: String, Sendable {
    case unknownChat
    case smsBlocked
    case unknownChatStyle
    case groupChat
    case tapbackOrEmpty
    case fromSelf
    case noSenderHandle
    case notAllowlisted
}

enum FilterDecision: Sendable {
    case capture(CapturedMessage)
    case drop(DropReason)
}
