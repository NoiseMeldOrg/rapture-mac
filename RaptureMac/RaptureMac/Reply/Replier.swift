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
        prePromptHandler: (@MainActor () -> Bool)? = nil
    ) {
        self.sender = sender
        self.echoGuard = echoGuard
        self.notifications = notifications
        self.stateStore = stateStore
        self.appState = appState
        self.prePromptHandler = prePromptHandler ?? { [weak appState] in
            AutomationPrompt.showPrePrompt(settings: appState?.settings) == .proceed
        }
    }

    /// Per-message reply gated by reply mode and isCatchup. `handoff` suffixes
    /// the success confirmation when a Reminders/Calendar item was created.
    func replyForWrite(
        captured: CapturedMessage,
        result: WriteResult,
        settings: Settings,
        handoff: HandoffOutcome = .none
    ) async {
        guard !captured.isCatchup else { return }
        guard let chatGuid = captured.event.chatGuid else {
            Self.log.debug("Skipping reply: no chatGuid")
            return
        }

        guard let text = Self.composeReplyText(
            replyMode: settings.replyMode, outcome: result.outcome, handoff: handoff,
            missingAttachments: result.failedAttachments.count
        ) else {
            return
        }
        await sendChat(chatGuid: chatGuid, text: text)
    }

    /// Reply for a capture spooled while the destination volume is absent.
    /// Same catch-up and chatGuid gating as `replyForWrite`.
    func replyForSpooled(captured: CapturedMessage, settings: Settings, destinationOffline: Bool = true) async {
        guard !captured.isCatchup else { return }
        guard let chatGuid = captured.event.chatGuid else {
            Self.log.debug("Skipping spooled reply: no chatGuid")
            return
        }
        guard let text = Self.composeSpooledReplyText(replyMode: settings.replyMode, destinationOffline: destinationOffline) else {
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
        guard Self.shouldSendCatchupSummary(successCount: successCount, failureCount: failureCount) else {
            Self.log.info("catch-up produced 0 captures and 0 failures — suppressing summary (echo-loop guard)")
            return
        }
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

    nonisolated static func composeReplyText(
        replyMode: ReplyMode,
        outcome: WriteResult.Outcome,
        handoff: HandoffOutcome = .none,
        missingAttachments: Int = 0
    ) -> String? {
        switch (replyMode, outcome) {
        case (.off, _):
            return nil
        case (.errorsOnly, .success):
            return nil
        case (.all, .success):
            return "✅ Saved" + Self.handoffSuffix(handoff) + Self.missingAttachmentSuffix(missingAttachments)
        case (_, .failure(let reason)):
            return "✗ \(reason)"
        case (_, .unavailable):
            // Momentary: the caller spools the capture and sends the queued reply.
            return nil
        }
    }

    /// The small confirmation suffix when a handoff fired alongside the filing
    /// (iMessage-sourced captures only; relay and spool paths reply nothing).
    nonisolated static func handoffSuffix(_ handoff: HandoffOutcome) -> String {
        switch (handoff.reminderCreated, handoff.eventCreated) {
        case (false, false): return ""
        case (true, false): return " · Reminder created"
        case (false, true): return " · Event created"
        case (true, true): return " · Reminder + event created"
        }
    }

    /// "✅ Saved" must not claim a photo that didn't make it: the note filed,
    /// but an attachment was not downloaded yet (it is retried in the background).
    nonisolated static func missingAttachmentSuffix(_ count: Int) -> String {
        guard count > 0 else { return "" }
        return " · \(count) \(count == 1 ? "attachment" : "attachments") missing"
    }

    /// Honest confirmation for a capture queued in the internal spool while the
    /// destination volume is absent: durable, but not in the notes folder yet.
    /// Success-tier, so `.errorsOnly` and `.off` stay silent; no second reply
    /// fires when the spool flushes.
    nonisolated static func composeSpooledReplyText(replyMode: ReplyMode, destinationOffline: Bool = true) -> String? {
        guard replyMode == .all else { return nil }
        // Captures also queue behind an older queued capture that won't file
        // (order is kept), with the drive online. Saying "offline" then is wrong.
        return destinationOffline ? "✅ Queued — destination offline" : "✅ Queued — waiting for an earlier note"
    }

    nonisolated static func composeCatchupText(successCount: Int, failureCount: Int) -> String {
        if failureCount > 0 {
            return "📥 Caught up: \(successCount) notes (\(failureCount) failed)"
        }
        return "📥 Caught up: \(successCount) notes"
    }

    /// Whether a catch-up summary should be sent at all. A catch-up batch that
    /// captured nothing AND failed nothing is entirely dropped messages — in
    /// practice our own `📥 Caught up: …` / `✅ Saved` confirmations re-entering
    /// as is_from_me=0 via iCloud multi-device sync. Emitting "Caught up: 0 notes"
    /// would add another message that echoes back, keeps the batch ≥ the backlog
    /// threshold, and re-triggers catch-up — an infinite self-sustaining loop
    /// (observed spamming the self-thread in 1.0.104). Nothing happened → no summary.
    nonisolated static func shouldSendCatchupSummary(successCount: Int, failureCount: Int) -> Bool {
        successCount > 0 || failureCount > 0
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
                // "Don't Send Replies" switched reply mode to Never: that is a
                // choice, not a missing permission, so no warning.
                appState.automationPermissionState = appState.settings.settings.replyMode == .off ? .unknown : .required
                return
            }
            appState.automationPermissionState = .unknown
        }

        do {
            try await sender.send(text: text, toChatGuid: chatGuid)
            echoGuard.track(chatGuid: chatGuid, text: text)
            appState.automationPermissionState = .ok
            appState.clearError(source: .reply)
            Self.log.info("Sent reply to chat=\(chatGuid, privacy: .public)")
        } catch let err as AppleScriptSendError {
            if err.isPermissionDenied {
                if appState.automationPermissionState != .required {
                    appState.automationPermissionState = .required
                    AutomationPrompt.showDenied()
                }
                appState.recordError("Automation permission needed for Messages", source: .reply)
            } else {
                Self.log.error("Send failed: \(err.userFacingMessage, privacy: .public)")
                appState.recordError("Reply failed: \(err.userFacingMessage)", source: .reply)
            }
        } catch {
            Self.log.error("Send failed: \(error.localizedDescription, privacy: .public)")
            appState.recordError("Reply failed: \(error.localizedDescription)", source: .reply)
        }
    }
}
