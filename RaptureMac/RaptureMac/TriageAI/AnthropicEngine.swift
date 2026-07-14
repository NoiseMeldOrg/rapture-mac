import Foundation
import OSLog

/// The BYO-key engine — the ONLY place in the app that performs an outbound
/// network request besides Sparkle (PRIVACY.md names this file; keep it that
/// way). Runs only when the user turned AI triage on, Apple Intelligence is
/// unavailable, and they pasted their own Anthropic API key. Front-guarded on
/// XCTest so the hosted test suite can never reach the network.
@MainActor
final class AnthropicEngine: AITriageEngine {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "AnthropicEngine")

    nonisolated let kind: AIEngineKind = .anthropic

    private let credentials: any CredentialStore

    init(credentials: any CredentialStore) {
        self.credentials = credentials
    }

    func availability() -> AIEngineAvailability {
        guard !ProcessInfo.processInfo.isRunningXCTests else {
            return .unavailable(reason: "The Anthropic engine is unavailable under tests")
        }
        guard credentials.anthropicAPIKey()?.isEmpty == false else {
            return .unavailable(reason: "No Anthropic API key is set")
        }
        return .available
    }

    func analyze(text: String, capturedAt: Date, timeZone: TimeZone) async throws -> AIEngineDraft {
        guard !ProcessInfo.processInfo.isRunningXCTests else { throw AIEngineError.unavailable }
        guard let key = credentials.anthropicAPIKey(), !key.isEmpty else { throw AIEngineError.unavailable }

        let request = AnthropicWire.makeRequest(
            apiKey: key,
            text: text,
            capturedAt: capturedAt,
            timeZone: timeZone
        )
        let data: Data
        let response: URLResponse
        do {
            // The await suspends off the main actor inside URLSession; the
            // service's timeout race (plus the request's own timeoutInterval)
            // bounds the wait.
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AIEngineError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try AnthropicWire.parseResponse(data: data, statusCode: status)
    }
}
