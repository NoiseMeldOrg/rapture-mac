import Foundation

/// The AI-triage seam the four composers call (`FileWriter`, `RelayFiler`,
/// `SpoolFlusher`, `TriageProcessor`). Mirrors `HandoffProcessing`: one method,
/// injected as an optional collaborator, fake-able in tests. A `nil` return —
/// toggle off, no engine, call failed, output rejected — means the deterministic
/// path composes exactly as it does today. AI never throws into a filing path
/// and never blocks it beyond the service's hard timeout.
@MainActor
protocol AITriageProviding: AnyObject {
    func analyze(text: String, capturedAt: Date) async -> AITriageOutput?
}

/// Validated AI result. Every field is independently optional: a discarded
/// field falls back to its deterministic value while the rest still apply.
struct AITriageOutput: Equatable, Sendable {
    /// task/idea/journal; nil = keep the deterministic type (voice-note → Notes/).
    var classification: CaptureType?
    /// Smart title; nil = deterministic `TitleDeriver` title.
    var title: String?
    /// Lightly formatted body; nil = body stays verbatim and no `## Raw` section.
    var formattedBody: String?
    /// Handoff candidates with their source clauses, already validated.
    /// Replaces `HandoffDetector` output for this capture when non-empty rules apply.
    var handoffs: [HandoffDetector.Detected] = []
    /// True when the draft *had* handoff candidates but every one was discarded
    /// by validation — the manager then falls back to the deterministic detector
    /// rather than letting a hallucinating model silently disable M3 behavior.
    var handoffsInvalidated = false
}

enum AIEngineKind: String, Sendable, Equatable {
    case apple
    case anthropic
}

/// Settings-facing engine status. Never surfaces on the menu bar (the handoff
/// rule: the note itself filed fine, so AI trouble is a Settings-only concern).
enum AIEngineStatus: Equatable, Sendable {
    /// Toggle off.
    case off
    case active(AIEngineKind)
    /// Toggle on, no usable engine; the reason is the honest Settings line.
    case unavailable(String)
}

enum AIEngineError: Error, Equatable {
    case timeout
    /// The model declined (safety guardrails); per-capture miss, not a transport strike.
    case refusal
    /// The response hit its token cap; output can't be trusted.
    case truncated
    /// Response arrived but didn't decode to a draft.
    case invalidOutput
    /// Non-200 HTTP status. 401 latches "key rejected" upstream.
    case http(Int)
    case network(String)
    /// Engine can't run at all (no model, no key, under XCTest).
    case unavailable
}

/// What engines return, pre-validation: the wire shape both engines converge
/// on. Codable so the Anthropic JSON decodes straight into it; the Apple
/// engine maps its `@Generable` mirror into the same struct.
struct AIEngineDraft: Equatable, Sendable, Codable {
    /// "task" | "idea" | "journal" | nil.
    var classification: String?
    var title: String?
    var formattedBody: String?
    var handoffs: [DraftHandoff] = []

    struct DraftHandoff: Equatable, Sendable, Codable {
        /// "reminder" | "event".
        var kind: String
        var title: String
        /// Verbatim clause from the note — validated by containment, then used
        /// for the ledger's clause fingerprint.
        var clause: String
        /// Local date parts (capture's time zone); all-or-nothing for events,
        /// partial reminder dates degrade to dateless.
        var year: Int?
        var month: Int?
        var day: Int?
        var hour: Int?
        var minute: Int?
    }
}

enum AIEngineAvailability: Equatable, Sendable {
    case available
    case unavailable(reason: String)
}

/// One engine (Apple on-device or Anthropic BYO-key). The service resolves
/// which one runs; engines only run when asked and throw typed errors.
/// `Sendable` so the existential can cross into the timeout race's child task;
/// conformers are `@MainActor` classes, which satisfy it implicitly.
@MainActor
protocol AITriageEngine: AnyObject, Sendable {
    var kind: AIEngineKind { get }
    func availability() -> AIEngineAvailability
    func analyze(text: String, capturedAt: Date, timeZone: TimeZone) async throws -> AIEngineDraft
}
