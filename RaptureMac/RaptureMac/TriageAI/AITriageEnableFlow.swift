import Foundation

/// The AI-triage toggle-enable decision, extracted from the view (the
/// `HandoffEnableFlow` pattern): the toggle persists ON only when an engine
/// would actually run. No TCC and no network here — resolution is a pure
/// status check — so this is simpler than the handoff flow (no pre-prompt).
/// If an engine becomes unavailable LATER, the toggle stays on (never silently
/// flip a user setting); the status line reports it and filing stays
/// deterministic.
@MainActor
enum AITriageEnableFlow {
    struct Result: Equatable {
        var enabled: Bool
        var status: AIEngineStatus
        /// Guidance caption when the toggle refused to enable.
        var error: String?
    }

    static func enable(service: AITriageService) -> Result {
        let status = service.resolutionStatus()
        switch status {
        case .active:
            return Result(enabled: true, status: status, error: nil)
        case .unavailable(let reason):
            return Result(
                enabled: false,
                status: status,
                error: "\(reason) Captures keep filing without AI."
            )
        case .off:
            // resolutionStatus() never returns .off; refuse defensively.
            return Result(enabled: false, status: status, error: nil)
        }
    }
}
