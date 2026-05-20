import Foundation
import OSLog

@MainActor
final class EchoGuard {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "EchoGuard")
    nonisolated static let ttl: TimeInterval = 15
    nonisolated static let normalizationCap = 120

    private let stateStore: StateStore
    private let clock: @Sendable () -> Date

    init(stateStore: StateStore, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.stateStore = stateStore
        self.clock = clock
    }

    func track(chatGuid: String, text: String) {
        let now = clock()
        stateStore.update { state in
            state.recentSentEchoes = Self.appendEntry(
                into: state.recentSentEchoes,
                chatGuid: chatGuid,
                text: text,
                now: now
            )
        }
    }

    func consume(chatGuid: String, text: String) -> Bool {
        let now = clock()
        var matched = false
        stateStore.update { state in
            let result = Self.consumeMatch(
                from: state.recentSentEchoes,
                chatGuid: chatGuid,
                text: text,
                now: now
            )
            matched = result.matched
            state.recentSentEchoes = result.remaining
        }
        return matched
    }

    // MARK: - Pure helpers (testable without StateStore)

    nonisolated static func appendEntry(
        into entries: [EchoEntry],
        chatGuid: String,
        text: String,
        now: Date
    ) -> [EchoEntry] {
        var kept = entries.filter { $0.expiresAt > now }
        kept.append(EchoEntry(
            chatGuid: chatGuid,
            normalizedText: normalize(text),
            expiresAt: now.addingTimeInterval(ttl)
        ))
        return kept
    }

    nonisolated static func consumeMatch(
        from entries: [EchoEntry],
        chatGuid: String,
        text: String,
        now: Date
    ) -> (matched: Bool, remaining: [EchoEntry]) {
        // Greedy: drop ALL matching entries, not just the first. iCloud's
        // multi-device sync re-delivers each outbound message to chat.db once
        // per paired device (Mac, iPhone, iPad, etc.), so one `track()` needs
        // to suppress N inbound echoes. The previous one-shot behavior
        // suppressed the first and let the rest cascade as captures.
        let normalized = normalize(text)
        var kept: [EchoEntry] = []
        kept.reserveCapacity(entries.count)
        var matched = false
        for entry in entries {
            if entry.expiresAt <= now { continue }
            if entry.chatGuid == chatGuid, entry.normalizedText == normalized {
                matched = true
                continue
            }
            kept.append(entry)
        }
        return (matched, kept)
    }

    nonisolated static func normalize(_ input: String) -> String {
        var text = input

        // 1. Strip " Sent by Claude" suffix (case-insensitive).
        if let range = text.range(
            of: " Sent by Claude",
            options: [.caseInsensitive, .backwards, .anchored]
        ) {
            text.removeSubrange(range)
        }

        // 2. Strip ZWJ and variation selectors.
        text = text.unicodeScalars.filter { scalar in
            if scalar.value == 0x200D { return false }
            if (0xFE00...0xFE0F).contains(scalar.value) { return false }
            return true
        }.reduce(into: "") { $0.append(Character($1)) }

        // 3. Smart quotes -> ASCII.
        text = text
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")

        // 4. Lowercase.
        text = text.lowercased()

        // 5. Collapse whitespace runs to single space.
        var collapsed = ""
        var lastWasWhitespace = false
        for char in text {
            if char.isWhitespace {
                if !lastWasWhitespace {
                    collapsed.append(" ")
                }
                lastWasWhitespace = true
            } else {
                collapsed.append(char)
                lastWasWhitespace = false
            }
        }
        text = collapsed

        // 6. Trim.
        text = text.trimmingCharacters(in: .whitespaces)

        // 7. Cap at 120 chars.
        if text.count > normalizationCap {
            text = String(text.prefix(normalizationCap))
        }

        return text
    }
}
