import Foundation
import Observation
import OSLog

/// The one AI entry point, called by the four composers just before compose.
/// Orchestrates: toggle gate → cooldown gate → engine resolution → clipped,
/// timeout-raced engine call → mechanical validation → status/error
/// bookkeeping. Strictly best-effort: every failure returns nil and the
/// capture files deterministically, immediately. AI trouble surfaces only via
/// `AppState.aiEngineStatus`/`aiLastError` (Settings), never the menu bar —
/// the handoff rule: the note itself files fine either way.
@Observable
@MainActor
final class AITriageService: AITriageProviding {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "AITriageService")

    /// Hard ceiling per capture. Haiku answers in ~1–3s and the on-device model
    /// in a few; 10s still "feels like seconds" for a background filer, and the
    /// cooldown below keeps it from compounding across a backlog drain.
    nonisolated static let requestTimeout: TimeInterval = 10
    /// After this many *consecutive* transport-class failures (timeout, network,
    /// non-401 HTTP), stop trying for `failureCooldown` — a dead network must
    /// not add 10s to every file of a 50-note drain.
    nonisolated static let cooldownThreshold = 2
    nonisolated static let failureCooldown: TimeInterval = 60

    private let appState: AppState
    private let appleEngine: (any AITriageEngine)?
    private let anthropicEngine: (any AITriageEngine)?
    private let clock: @Sendable () -> Date
    /// Read at each use, never captured at init (house rule — the zone can change mid-run).
    private let timeZoneProvider: @Sendable () -> TimeZone
    private let timeout: TimeInterval

    /// One 401 stops per-capture retries until the user re-saves a key.
    private(set) var keyRejected = false
    private var consecutiveTransportFailures = 0
    private var cooldownUntil: Date?

    init(
        appState: AppState,
        appleEngine: (any AITriageEngine)? = nil,
        anthropicEngine: (any AITriageEngine)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        timeZoneProvider: @escaping @Sendable () -> TimeZone = { .current },
        timeout: TimeInterval = AITriageService.requestTimeout
    ) {
        self.appState = appState
        self.appleEngine = appleEngine
        self.anthropicEngine = anthropicEngine
        self.clock = clock
        self.timeZoneProvider = timeZoneProvider
        self.timeout = timeout
    }

    // MARK: - AITriageProviding

    func analyze(text: String, capturedAt: Date) async -> AITriageOutput? {
        guard appState.settings.settings.aiTriageEnabled else {
            appState.aiEngineStatus = .off
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let cooldownUntil, clock() < cooldownUntil {
            return nil
        }

        // Resolved fresh per call: Apple availability and the key can both
        // change mid-run (model download finishes, key saved in Settings).
        let engine: any AITriageEngine
        switch resolve() {
        case .apple:
            guard let appleEngine else { return nil }
            engine = appleEngine
        case .anthropic:
            guard let anthropicEngine else { return nil }
            engine = anthropicEngine
        case .none(let reason):
            appState.aiEngineStatus = .unavailable(reason)
            return nil
        }

        let zone = timeZoneProvider()
        let (clipped, truncated) = AITriagePrompt.clip(text)

        do {
            let draft = try await Self.withTimeout(timeout) {
                try await engine.analyze(text: clipped, capturedAt: capturedAt, timeZone: zone)
            }
            noteSuccess(engine.kind)
            return AITriageValidator.validate(
                draft: draft,
                rawText: text,
                truncated: truncated,
                capturedAt: capturedAt,
                timeZone: zone
            )
        } catch let error as AIEngineError {
            noteFailure(error, engine: engine.kind)
            return nil
        } catch {
            noteFailure(.network(error.localizedDescription), engine: engine.kind)
            return nil
        }
    }

    // MARK: - Status (Settings surface)

    /// Resolution ignoring the toggle — what WOULD run. The enable flow uses
    /// this to decide whether the toggle may persist ON.
    func resolutionStatus() -> AIEngineStatus {
        switch resolve() {
        case .apple: return .active(.apple)
        case .anthropic: return .active(.anthropic)
        case .none(let reason): return .unavailable(reason)
        }
    }

    /// Settings calls this on section appear, toggle change, and key save.
    func refreshStatus() {
        guard appState.settings.settings.aiTriageEnabled else {
            appState.aiEngineStatus = .off
            return
        }
        appState.aiEngineStatus = resolutionStatus()
    }

    /// A freshly saved key clears the 401 latch and any cooldown so the next
    /// capture tries immediately.
    func noteKeySaved() {
        keyRejected = false
        consecutiveTransportFailures = 0
        cooldownUntil = nil
        appState.aiLastError = nil
        refreshStatus()
    }

    // MARK: - Internals

    private func resolve() -> AIEngineResolver.Resolution {
        var availability = appleEngine?.availability() ?? .unavailable(reason: "Apple Intelligence isn't available on this Mac")
        #if DEBUG
        // Live-verification hook: force the BYO-key path on a Mac where Apple
        // Intelligence is available. Debug builds only, never shipped behavior.
        if ProcessInfo.processInfo.environment["RAPTURE_AI_FORCE_ENGINE"] == "anthropic" {
            availability = .unavailable(reason: "Apple engine disabled by RAPTURE_AI_FORCE_ENGINE")
        }
        #endif
        let appleAvailable: Bool
        let appleReason: String?
        switch availability {
        case .available:
            appleAvailable = true
            appleReason = nil
        case .unavailable(let reason):
            appleAvailable = false
            appleReason = reason
        }
        return AIEngineResolver.resolve(
            appleAvailable: appleAvailable,
            appleUnavailableReason: appleReason,
            hasAPIKey: appState.credentials.anthropicAPIKey()?.isEmpty == false,
            keyRejected: keyRejected
        )
    }

    private func noteSuccess(_ kind: AIEngineKind) {
        consecutiveTransportFailures = 0
        cooldownUntil = nil
        appState.aiEngineStatus = .active(kind)
        appState.aiLastError = nil
    }

    private func noteFailure(_ error: AIEngineError, engine kind: AIEngineKind) {
        switch error {
        case .http(401):
            keyRejected = true
            report("Anthropic rejected the API key — check it in Settings › Triage")
            refreshStatus()
        case .timeout:
            transportStrike("AI triage timed out — captures are filing without it")
        case .network(let description):
            transportStrike("AI triage couldn't reach the network: \(description)")
        case .http(let status):
            transportStrike("Anthropic returned HTTP \(status) — captures are filing without AI")
        case .refusal:
            // Per-capture miss, not a transport strike: the next capture is fine.
            report("The AI engine declined this capture; it filed deterministically")
        case .truncated, .invalidOutput:
            report("The AI engine returned unusable output; the capture filed deterministically")
        case .unavailable:
            refreshStatus()
        }
        Self.log.error("engine \(kind.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
    }

    private func transportStrike(_ message: String) {
        consecutiveTransportFailures += 1
        if consecutiveTransportFailures >= Self.cooldownThreshold {
            cooldownUntil = clock().addingTimeInterval(Self.failureCooldown)
        }
        report(message)
    }

    private func report(_ message: String) {
        appState.aiLastError = message
    }

    // MARK: - Timeout race (pure structured concurrency)

    /// Races the operation against a deadline; the loser is cancelled (both
    /// engines' underlying transports honor task cancellation).
    nonisolated static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw AIEngineError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw AIEngineError.timeout
            }
            return first
        }
    }
}
