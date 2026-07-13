import Foundation

struct WriteResult: Sendable {
    enum Outcome: Sendable {
        case success(URL)
        case failure(reason: String)
        /// The destination's volume is absent (see `DestinationGuard`). Nothing
        /// was written or created; the caller queues the capture instead.
        case unavailable
    }

    let outcome: Outcome
    let failedAttachments: [String]

    var isSuccess: Bool {
        if case .success = outcome { return true }
        return false
    }
}
