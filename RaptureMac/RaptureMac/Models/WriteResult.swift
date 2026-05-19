import Foundation

struct WriteResult: Sendable {
    enum Outcome: Sendable {
        case success(URL)
        case failure(reason: String)
    }

    let outcome: Outcome
    let failedAttachments: [String]

    var isSuccess: Bool {
        if case .success = outcome { return true }
        return false
    }
}
