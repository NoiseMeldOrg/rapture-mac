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
    /// The AI triage result the composer consulted for this capture, echoed
    /// back so the processor can forward its handoff candidates into
    /// `HandoffProcessing` without re-reading the capture text. nil = AI off,
    /// unavailable, failed, or not applicable (links, raw mode).
    var ai: AITriageOutput? = nil

    var isSuccess: Bool {
        if case .success = outcome { return true }
        return false
    }
}
