import Foundation
@testable import Rapture

/// Scriptable `AITriageProviding` spy — the composer-facing fake (mirrors
/// `SpyHandoff`). Returns a canned output and records every call.
@MainActor
final class FakeAITriage: AITriageProviding {
    var output: AITriageOutput?
    private(set) var calls: [(text: String, capturedAt: Date)] = []

    init(output: AITriageOutput? = nil) {
        self.output = output
    }

    func analyze(text: String, capturedAt: Date) async -> AITriageOutput? {
        calls.append((text, capturedAt))
        return output
    }
}

/// Scriptable `AITriageEngine` — the service-facing fake. Behavior per call:
/// canned draft, canned error, or an indefinite (cancellation-aware) hang for
/// timeout tests. Never touches a model or the network.
@MainActor
final class FakeAITriageEngine: AITriageEngine {
    enum Behavior {
        case draft(AIEngineDraft)
        case error(AIEngineError)
        /// Sleeps far past any test timeout; honors cancellation (so the
        /// service's timeout race can reap it).
        case hang
    }

    nonisolated let kind: AIEngineKind
    var behavior: Behavior
    var availabilityResult: AIEngineAvailability = .available
    private(set) var analyzeCalls: [(text: String, capturedAt: Date, timeZone: TimeZone)] = []

    init(kind: AIEngineKind, behavior: Behavior = .draft(AIEngineDraft())) {
        self.kind = kind
        self.behavior = behavior
    }

    func availability() -> AIEngineAvailability {
        availabilityResult
    }

    func analyze(text: String, capturedAt: Date, timeZone: TimeZone) async throws -> AIEngineDraft {
        analyzeCalls.append((text, capturedAt, timeZone))
        switch behavior {
        case .draft(let draft):
            return draft
        case .error(let error):
            throw error
        case .hang:
            try await Task.sleep(for: .seconds(3600))
            throw AIEngineError.timeout
        }
    }
}

/// In-memory `CredentialStore` — no keychain contact.
@MainActor
final class FakeCredentialStore: CredentialStore {
    var key: String?
    var setError: Error?
    private(set) var setCalls: [String?] = []

    init(key: String? = nil) {
        self.key = key
    }

    func anthropicAPIKey() -> String? { key }

    func setAnthropicAPIKey(_ newKey: String?) throws {
        if let setError { throw setError }
        setCalls.append(newKey)
        key = newKey
    }
}
