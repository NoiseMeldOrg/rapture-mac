import Foundation
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The Apple on-device engine — the ONLY file importing FoundationModels.
/// Deployment target stays macOS 14: the framework weak-links via availability
/// annotations, and every entry is additionally front-guarded on XCTest (the
/// hosted test bundle must never touch the system model — same defense-in-depth
/// as `SystemEventKitClient`). Construction is inert.
@MainActor
final class AppleFoundationEngine: AITriageEngine {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "AppleFoundationEngine")

    nonisolated let kind: AIEngineKind = .apple

    func availability() -> AIEngineAvailability {
        guard !ProcessInfo.processInfo.isRunningXCTests else {
            return .unavailable(reason: "Apple Intelligence is unavailable under tests")
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                return .unavailable(reason: Self.describe(reason))
            }
        }
        #endif
        return .unavailable(reason: "Apple Intelligence requires macOS 26 or later")
    }

    func analyze(text: String, capturedAt: Date, timeZone: TimeZone) async throws -> AIEngineDraft {
        guard !ProcessInfo.processInfo.isRunningXCTests else { throw AIEngineError.unavailable }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return try await analyzeWithModel(text: text, capturedAt: capturedAt, timeZone: timeZone)
        }
        #endif
        throw AIEngineError.unavailable
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func analyzeWithModel(text: String, capturedAt: Date, timeZone: TimeZone) async throws -> AIEngineDraft {
        // A fresh session per capture: no cross-capture context bleed, and the
        // shared instructions stay the single source of truth for both engines.
        let session = LanguageModelSession(instructions: AITriagePrompt.instructions)
        let prompt = AITriagePrompt.userMessage(text: text, capturedAt: capturedAt, timeZone: timeZone)
        do {
            let response = try await session.respond(to: prompt, generating: GenerableTriage.self)
            return response.content.draft
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation:
                throw AIEngineError.refusal
            case .exceededContextWindowSize:
                throw AIEngineError.truncated
            default:
                Self.log.error("generation failed: \(String(describing: error), privacy: .public)")
                throw AIEngineError.invalidOutput
            }
        } catch {
            Self.log.error("session failed: \(error.localizedDescription, privacy: .public)")
            throw AIEngineError.invalidOutput
        }
    }

    @available(macOS 26.0, *)
    private nonisolated static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This Mac doesn't support Apple Intelligence"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is turned off in System Settings"
        case .modelNotReady:
            return "The Apple Intelligence model is still downloading"
        @unknown default:
            return "Apple Intelligence isn't available right now"
        }
    }
    #endif
}

#if canImport(FoundationModels)
/// Guided-generation mirror of `AIEngineDraft`. Kept in this file so the
/// FoundationModels dependency stays confined.
@available(macOS 26.0, *)
@Generable
private struct GenerableTriage {
    @Guide(description: "Exactly one of: task, idea, journal, none. Use none when unsure.")
    var classification: String

    @Guide(description: "3 to 10 word title; concise imperative for tasks; no invented content.")
    var title: String?

    @Guide(description: "The note text with light punctuation/paragraph cleanup only; omit if already clean.")
    var formattedBody: String?

    @Guide(description: "Reminder/event handoffs; at most one of each; only when unambiguous.")
    var handoffs: [GenerableHandoff]

    var draft: AIEngineDraft {
        AIEngineDraft(
            classification: classification.lowercased() == "none" ? nil : classification,
            title: title,
            formattedBody: formattedBody,
            handoffs: handoffs.map(\.draft)
        )
    }
}

@available(macOS 26.0, *)
@Generable
private struct GenerableHandoff {
    @Guide(description: "reminder or event")
    var kind: String
    @Guide(description: "Concise imperative title for the created item")
    var title: String
    @Guide(description: "The verbatim clause from the note this came from, copied exactly")
    var clause: String
    @Guide(description: "Local year, only if the note states or implies a date")
    var year: Int?
    @Guide(description: "Local month (1-12), only if stated")
    var month: Int?
    @Guide(description: "Local day of month, only if stated")
    var day: Int?
    @Guide(description: "Local hour (0-23), only if a time is stated")
    var hour: Int?
    @Guide(description: "Local minute (0-59), only if a time is stated")
    var minute: Int?

    var draft: AIEngineDraft.DraftHandoff {
        AIEngineDraft.DraftHandoff(
            kind: kind, title: title, clause: clause,
            year: year, month: month, day: day, hour: hour, minute: minute
        )
    }
}
#endif
