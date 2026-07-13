import Foundation
import OSLog

@MainActor
final class Replier {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "Replier")

    private let sender: AppleScriptSending
    private let echoGuard: EchoGuard
    private let notifications: NotificationDispatching
    private let stateStore: StateStore
    private let appState: AppState
    private let prePromptHandler: @MainActor () -> Bool

    /// `prePromptHandler` returns `true` if the user acknowledged and we should proceed, `false` to abort.
    /// In production this calls `AutomationPrompt.showPrePrompt()`; tests can inject a stub.
    init(
        sender: AppleScriptSending,
        echoGuard: EchoGuard,
        notifications: NotificationDispatching,
        stateStore: StateStore,
        appState: AppState,
        prePromptHandler: @MainActor @escaping () -> Bool = { AutomationPrompt.showPrePrompt() == .proceed }
    ) {
        self.sender = sender
        self.echoGuard = echoGuard
        self.notifications = notifications
        self.stateStore = stateStore
        self.appState = appState
        self.prePromptHandler = prePromptHandler
    }

    /// Per-message reply gated by reply mode and isCatchup.
    func replyForWrite(captured: CapturedMessage, result: WriteResult, settings: Settings) async {
        guard !captured.isCatchup else { return }
        guard let chatGuid = captured.event.chatGuid else {
            Self.log.debug("Skipping reply: no chatGuid")
            return
        }

        guard let text = Self.composeReplyText(replyMode: settings.replyMode, outcome: result.outcome) else {
            return
        }
        await sendChat(chatGuid: chatGuid, text: text)
    }

    /// Reply for a capture spooled while the destination volume is absent.
    /// Same catch-up and chatGuid gating as `replyForWrite`.
    func replyForSpooled(captured: CapturedMessage, settings: Settings) async {
        guard !captured.isCatchup else { return }
        guard let chatGuid = captured.event.chatGuid else {
            Self.log.debug("Skipping spooled reply: no chatGuid")
            return
        }
        guard let text = Self.composeSpooledReplyText(replyMode: settings.replyMode) else {
            return
        }
        await sendChat(chatGuid: chatGuid, text: text)
    }

    /// Single summary reply for catch-up batches with > 3 messages.
    func sendCatchupSummary(
        successCount: Int,
        failureCount: Int,
        selfChatGuid: String?,
        replyMode: ReplyMode
    ) async {
        let text = Self.composeCatchupText(successCount: successCount, failureCount: failureCount)
        let destination = Self.catchupDestination(replyMode: replyMode, selfChatGuid: selfChatGuid)
        switch destination {
        case .chat(let guid):
            await sendChat(chatGuid: guid, text: text)
        case .notification:
            await notifications.send(title: "Rapture caught up", body: text)
        }
    }

    // MARK: - Pure helpers (testable without dependencies)

    enum CatchupDestination: Equatable {
        case chat(String)
        case notification
    }

    nonisolated static func composeReplyText(replyMode: ReplyMode, outcome: WriteResult.Outcome) -> String? {
        switch (replyMode, outcome) {
        case (.off, _):
            return nil
        case (.errorsOnly, .success):
            return nil
        case (.all, .success):
            return "✅ Saved"
        case (_, .failure(let reason)):
            return "✗ \(reason)"
        case (_, .unavailable):
            // Momentary: the caller spools the capture and sends the queued reply.
            return nil
        }
    }

    /// Honest confirmation for a capture queued in the internal spool while the
    /// destination volume is absent: durable, but not in the notes folder yet.
    /// Success-tier, so `.errorsOnly` and `.off` stay silent; no second reply
    /// fires when the spool flushes.
    nonisolated static func composeSpooledReplyText(replyMode: ReplyMode) -> String? {
        guard replyMode == .all else { return nil }
        return "✅ Queued — destination offline"
    }

    nonisolated static func composeCatchupText(successCount: Int, failureCount: Int) -> String {
        if failureCount > 0 {
            return "📥 Caught up: \(successCount) notes (\(failureCount) failed)"
        }
        return "📥 Caught up: \(successCount) notes"
    }

    nonisolated static func catchupDestination(replyMode: ReplyMode, selfChatGuid: String?) -> CatchupDestination {
        if replyMode == .off { return .notification }
        if let guid = selfChatGuid { return .chat(guid) }
        return .notification
    }

    private func sendChat(chatGuid: String, text: String) async {
        // One-shot pre-prompt before the very first send.
        if !stateStore.state.automationPrePromptShown {
            appState.automationPermissionState = .prePromptPending
            let proceed = prePromptHandler()
            stateStore.update { $0.automationPrePromptShown = true }
            guard proceed else {
                appState.automationPermissionState = .required
                return
            }
            appState.automationPermissionState = .unknown
        }

        do {
            try await sender.send(text: text, toChatGuid: chatGuid)
            echoGuard.track(chatGuid: chatGuid, text: text)
            appState.automationPermissionState = .ok
            Self.log.info("Sent reply to chat=\(chatGuid, privacy: .public)")
        } catch let err as AppleScriptSendError {
            if err.isPermissionDenied {
                if appState.automationPermissionState != .required {
                    appState.automationPermissionState = .required
                    AutomationPrompt.showDenied()
                }
                appState.recordError("Automation permission needed for Messages")
            } else {
                Self.log.error("Send failed: \(err.userFacingMessage, privacy: .public)")
                appState.recordError("Reply failed: \(err.userFacingMessage)")
            }
        } catch {
            Self.log.error("Send failed: \(error.localizedDescription, privacy: .public)")
            appState.recordError("Reply failed: \(error.localizedDescription)")
        }
    }
}
