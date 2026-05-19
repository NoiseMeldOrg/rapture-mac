import Foundation

enum MessageFilter {
    static let groupChatStyle = 43

    static func decide(
        event: MessageEvent,
        selfHandles: Set<String>,
        settings: Settings,
        isCatchup: Bool = false
    ) -> FilterDecision {
        guard event.chatGuid != nil else { return .drop(.unknownChat) }

        if event.service != "iMessage" && !settings.allowSMS {
            return .drop(.smsBlocked)
        }

        guard let style = event.chatStyle else { return .drop(.unknownChatStyle) }
        if style == groupChatStyle { return .drop(.groupChat) }

        if event.isFromMe { return .drop(.fromSelf) }

        let decodedText = event.text ?? AttributedBodyDecoder.decode(event.attributedBody) ?? ""
        let trimmed = decodedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && event.attachments.isEmpty {
            return .drop(.tapbackOrEmpty)
        }

        guard let handleId = event.handleId else { return .drop(.noSenderHandle) }

        let normalizedHandle = SelfHandleResolver.normalize(handleId)
        let isSelfChat = selfHandles.contains(normalizedHandle)
        let allowed = settings.allowedHandles.contains { $0 == handleId || SelfHandleResolver.normalize($0) == normalizedHandle }

        guard isSelfChat || allowed else { return .drop(.notAllowlisted) }

        return .capture(CapturedMessage(
            event: event,
            decodedText: decodedText,
            isCatchup: isCatchup
        ))
    }
}
