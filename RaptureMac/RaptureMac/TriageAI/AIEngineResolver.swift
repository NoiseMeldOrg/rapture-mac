import Foundation

/// Pure engine resolution: Apple on-device first (private, free), else the
/// BYO-key Anthropic engine, else none with an honest reason for the Settings
/// status line. Truth-table tested.
enum AIEngineResolver {
    enum Resolution: Equatable, Sendable {
        case apple
        case anthropic
        case none(reason: String)
    }

    /// - Parameter keyRejected: a prior 401 latched until the key is re-saved,
    ///   so a bad key never hammers the API once per capture.
    nonisolated static func resolve(
        appleAvailable: Bool,
        appleUnavailableReason: String?,
        hasAPIKey: Bool,
        keyRejected: Bool
    ) -> Resolution {
        if appleAvailable { return .apple }
        if hasAPIKey && !keyRejected { return .anthropic }

        let appleReason = appleUnavailableReason ?? "Apple Intelligence isn't available on this Mac"
        let keyReason: String
        if !hasAPIKey {
            keyReason = "no Anthropic API key is set"
        } else {
            keyReason = "the saved Anthropic API key was rejected — check it below"
        }
        return .none(reason: "\(appleReason), and \(keyReason).")
    }
}
