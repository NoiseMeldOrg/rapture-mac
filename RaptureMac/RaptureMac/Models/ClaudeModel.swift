import Foundation

/// Which engine AI triage prefers. Apple Intelligence (on-device, free,
/// private) stays the default; choosing Claude sends each capture's text to
/// Anthropic with the user's own key, and only then.
enum AIEnginePreference: String, Codable, Sendable, CaseIterable {
    case appleFirst
    case claude
}

/// The Claude model the BYO-key engine calls. Sonnet 5.5 is the default when a
/// user picks Claude; Haiku 4.5 is the cheaper, faster choice.
enum ClaudeModel: String, Codable, Sendable, CaseIterable {
    case sonnet55 = "claude-sonnet-5-5"
    case haiku45 = "claude-haiku-4-5"

    var displayName: String {
        switch self {
        case .sonnet55: return "Claude Sonnet 5.5"
        case .haiku45: return "Claude Haiku 4.5"
        }
    }

    var note: String {
        switch self {
        case .sonnet55: return "Sharper titles and sorting. Costs about twice as much per note as Haiku, a few seconds per note."
        case .haiku45: return "Fastest and cheapest. Fine for short, simple notes."
        }
    }

    /// `output_config.effort`. Titling and sorting a short note is a
    /// classification task: `low` keeps Sonnet 5.5's thinking short and its
    /// answer quick. Haiku 4.5 rejects the effort parameter, so it sends none.
    var effort: String? {
        switch self {
        case .sonnet55: return "low"
        case .haiku45: return nil
        }
    }

    /// Room for the JSON answer, plus Sonnet 5.5's (brief) thinking, which
    /// counts toward `max_tokens`.
    var maxTokens: Int {
        switch self {
        case .sonnet55: return 4096
        case .haiku45: return 2048
        }
    }

    /// Sonnet 5.5 thinks before answering, even briefly, so it gets more time
    /// before a capture files without AI.
    var timeout: TimeInterval {
        switch self {
        case .sonnet55: return 15
        case .haiku45: return 10
        }
    }

    /// Server-side refusal fallback (`fallbacks: "default"`): a false-positive
    /// safety decline is retried on the model Anthropic recommends instead of
    /// failing the capture's AI step. Sonnet 5.5 on the Claude API only.
    var usesServerFallback: Bool { self == .sonnet55 }
}
