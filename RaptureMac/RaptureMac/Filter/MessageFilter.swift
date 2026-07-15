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

        // Defense in depth: drop our own confirmation messages even if echo guard
        // missed them (e.g., stale watermark, expired TTL, iCloud multi-device echo).
        // These come back through iCloud sync with is_from_me=0 but are clearly the
        // app's own outbound. The pattern is highly specific to the format we send,
        // so false-positives on natural user dictation are vanishingly unlikely.
        if isSelfChat && Self.looksLikeAppConfirmation(trimmed) {
            return .drop(.appConfirmation)
        }

        return .capture(CapturedMessage(
            event: event,
            decodedText: decodedText,
            isCatchup: isCatchup
        ))
    }

    /// True when `text` matches the structure of an outbound confirmation that
    /// the app itself sends via `osascript`. Covers every shape `Replier` can
    /// emit (`✅ Saved` with or without a handoff suffix, `✅ Queued — …`,
    /// `📥 Caught up: …`, `✗ …`) plus the legacy `✓ Saved: <filename>` form that
    /// may still echo back through iCloud sync from before the short-form
    /// upgrade. Pure, exposed `static` for unit testing.
    ///
    /// **Every branch here must stay in lockstep with `Replier`'s composers.**
    /// This matcher is the last line of defense when the echo guard misses an
    /// iCloud-relayed copy of our own reply, and the failure is silent and
    /// expensive: the reply files as a note, and — since M4 — AI triage happily
    /// classifies "✅ Saved · Reminder created" as a task and hands it off, so a
    /// junk reminder appears too. That is a real incident (2026-07-14), caused by
    /// this function testing `== "✅ Saved"` while M3 had started appending a
    /// handoff suffix and M2 had added the queued reply. `ReplierEchoFilterTests`
    /// now enumerates Replier's outputs and asserts each one lands here, so the
    /// two can't drift apart again.
    static func looksLikeAppConfirmation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // ✅ Saved                          (no handoff)
        // ✅ Saved · Reminder created       (Replier.handoffSuffix)
        // ✅ Saved · Event created
        // ✅ Saved · Reminder + event created
        // Prefix-matched on the separator rather than enumerating suffixes, so a
        // new handoff kind can't reintroduce the 2026-07-14 echo. Bare equality
        // stays first so the no-suffix form doesn't depend on the separator.
        if trimmed == "✅ Saved" { return true }
        if trimmed.hasPrefix("✅ Saved · ") { return true }

        // ✅ Queued — destination offline   (Replier.composeSpooledReplyText)
        if trimmed == "✅ Queued — destination offline" { return true }

        // ✓ Saved: 2026-05-20T19-16-54Z.txt
        // ✓ Saved: 2026-05-20T19-16-54Z-3.txt
        // Legacy: kept so pre-upgrade replays still get suppressed.
        if let body = trimmed.stripping(prefix: "✓ Saved: ") {
            return Self.looksLikeNoteFilename(body)
        }

        // 📥 Caught up: 5 notes
        // 📥 Caught up: 5 notes (1 failed)
        // 📥 Caught up: 5 notes captured  (legacy long form)
        if trimmed.hasPrefix("📥 Caught up: ") {
            return true
        }

        // ✗ <reason> — the failure-reply form. Reasons we send are short user-facing
        // strings ("Folder not writable", "Reply failed: ..."). A natural dictation
        // beginning with the U+2717 cross is implausible. Drop conservatively.
        if trimmed.hasPrefix("✗ ") || trimmed.hasPrefix("✗\u{00A0}") {
            return true
        }

        return false
    }

    /// Matches the timestamped filenames produced by `FileWriter.baseName`:
    /// ISO8601 UTC with `:` → `-`, optionally suffixed with `-N` for collisions,
    /// always ending in `.txt`. Example: `2026-05-20T19-16-54Z-3.txt`.
    private static func looksLikeNoteFilename(_ s: String) -> Bool {
        // Required suffix
        guard s.hasSuffix(".txt") else { return false }
        let stem = String(s.dropLast(4))

        // ISO timestamp head: YYYY-MM-DDTHH-MM-SSZ (20 chars)
        guard stem.count >= 20 else { return false }
        let head = stem.prefix(20)
        let tail = stem.dropFirst(20)

        let headChars = Array(head)
        // Char positions for date/time/punctuation
        let digitIndexes = [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18]
        for i in digitIndexes where !headChars[i].isNumber { return false }
        guard headChars[4] == "-", headChars[7] == "-", headChars[10] == "T",
              headChars[13] == "-", headChars[16] == "-", headChars[19] == "Z" else {
            return false
        }

        // Optional `-N` collision suffix
        if tail.isEmpty { return true }
        guard tail.hasPrefix("-") else { return false }
        let n = tail.dropFirst()
        return !n.isEmpty && n.allSatisfy { $0.isNumber }
    }
}

private extension String {
    /// Returns `self` with `prefix` removed if present, else `nil`.
    func stripping(prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
