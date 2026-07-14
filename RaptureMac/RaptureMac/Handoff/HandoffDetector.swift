import Foundation

/// Conservative deterministic handoff detection. An unambiguous reminder
/// trigger ("remind me to…", "remember to…", "don't forget…", "make sure
/// to…") yields a Reminder candidate; a trigger-less clause with an
/// appointment keyword AND an explicit date AND a time yields a Calendar-event
/// candidate. Anything short of that bar detects nothing — the note just
/// files. Title cleanup is strictly mechanical (trigger + date phrase
/// stripped, whitespace collapsed); smart imperative titling is the AI tier's
/// job (M4), which plugs in behind the same seam. Pure; table-tested.
enum HandoffDetector {
    enum Candidate: Equatable, Sendable {
        /// `due` nil = dateless reminder (the trigger alone is unambiguous).
        case reminder(title: String, due: HandoffDateParser.Resolved?)
        /// 1-hour default duration is applied by the manager, not here.
        case event(title: String, start: Date)
    }

    /// A candidate plus the verbatim clause it came from. The clause feeds the
    /// ledger's clause fingerprint (M4): re-dictations of the same utterance
    /// fingerprint identically whether the deterministic or the AI tier detected
    /// them, even though AI smart titles vary run to run.
    struct Detected: Equatable, Sendable {
        let candidate: Candidate
        let clause: String
    }

    nonisolated static let titleMaxChars = 60

    /// At most one reminder and one event per note: clauses scan in order and
    /// the first match of each kind wins. A clause containing a reminder
    /// trigger is a reminder clause, never an event (locked decision: the user
    /// said the word, honor it — "remind me to call John tomorrow at 2" pings
    /// at 2pm rather than booking time).
    nonisolated static func detect(_ text: String, capturedAt: Date, timeZone: TimeZone) -> [Candidate] {
        detectDetailed(text, capturedAt: capturedAt, timeZone: timeZone).map(\.candidate)
    }

    /// Same scan as `detect`, carrying each candidate's source clause.
    nonisolated static func detectDetailed(_ text: String, capturedAt: Date, timeZone: TimeZone) -> [Detected] {
        var reminder: Detected?
        var event: Detected?
        for clause in clauses(of: text) {
            if isReminderClause(clause) {
                if reminder == nil,
                   let candidate = reminderCandidate(in: clause, capturedAt: capturedAt, timeZone: timeZone) {
                    reminder = Detected(candidate: candidate, clause: clause)
                }
                continue
            }
            if event == nil,
               let candidate = eventCandidate(in: clause, capturedAt: capturedAt, timeZone: timeZone) {
                event = Detected(candidate: candidate, clause: clause)
            }
            if reminder != nil && event != nil { break }
        }
        return [reminder, event].compactMap { $0 }
    }

    // MARK: - Clause splitting

    /// Sentence-ending punctuation only when followed by whitespace or the end
    /// of the note, so "9:30 p.m." doesn't shatter; newlines always split.
    private nonisolated static let clauseBoundary = try! NSRegularExpression(
        pattern: #"[.?!;]+(?=\s|$)|\n+"#
    )

    nonisolated static func clauses(of text: String) -> [String] {
        let mutable = NSMutableString(string: text)
        clauseBoundary.replaceMatches(
            in: mutable,
            range: NSRange(location: 0, length: mutable.length),
            withTemplate: "\n"
        )
        return (mutable as String)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Reminders

    /// The locked trigger set (PRD M3 + the user's proven rulebook). Curly and
    /// straight apostrophes both — Siri emits curly.
    private nonisolated static let reminderTrigger = try! NSRegularExpression(
        pattern: #"\b(?:remind me to|remember to|don(?:'|’)t forget(?: to)?|make sure to)\s+(\S.*)$"#,
        options: [.caseInsensitive]
    )
    private nonisolated static let reminderTriggerPresence = try! NSRegularExpression(
        pattern: #"\b(?:remind me to|remember to|don(?:'|’)t forget|make sure to)\b"#,
        options: [.caseInsensitive]
    )

    nonisolated static func isReminderClause(_ clause: String) -> Bool {
        let full = NSRange(location: 0, length: (clause as NSString).length)
        return reminderTriggerPresence.firstMatch(in: clause, range: full) != nil
    }

    private nonisolated static func reminderCandidate(
        in clause: String, capturedAt: Date, timeZone: TimeZone
    ) -> Candidate? {
        let ns = clause as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = reminderTrigger.firstMatch(in: clause, range: full),
              let payloadRange = Range(match.range(at: 1), in: clause) else { return nil }
        // Parse the date phrase within the payload (its own string, so the
        // resolved ranges index into it), then strip it from the title.
        let payload = String(clause[payloadRange])
        let due = HandoffDateParser.parse(in: payload, reference: capturedAt, timeZone: timeZone)
        let stripped = due.map { removing(ranges: $0.consumedRanges, from: payload) } ?? payload
        guard let title = cleanTitle(stripped, strippingLeadingArticle: false) else { return nil }
        return .reminder(title: title, due: due)
    }

    // MARK: - Events

    /// The locked appointment-keyword anchor: without one of these, a dated
    /// clause is not an event (deterministic tier; M4's AI widens this).
    private nonisolated static let eventKeyword = try! NSRegularExpression(
        pattern: #"\b(?:appointment|appt|meeting|call)\b"#,
        options: [.caseInsensitive]
    )

    private nonisolated static func eventCandidate(
        in clause: String, capturedAt: Date, timeZone: TimeZone
    ) -> Candidate? {
        let full = NSRange(location: 0, length: (clause as NSString).length)
        guard eventKeyword.firstMatch(in: clause, range: full) != nil,
              let resolved = HandoffDateParser.parse(in: clause, reference: capturedAt, timeZone: timeZone),
              resolved.hasTime, resolved.hasExplicitDay else { return nil }
        let stripped = removing(ranges: resolved.consumedRanges, from: clause)
        guard let title = cleanTitle(stripped, strippingLeadingArticle: true) else { return nil }
        return .event(title: title, start: resolved.date)
    }

    // MARK: - Mechanical title cleanup

    nonisolated static func cleanTitle(_ raw: String, strippingLeadingArticle: Bool) -> String? {
        var title = raw
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")

        // Trailing punctuation and a trailing "please" can nest ("…, please.");
        // strip until stable.
        let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", "-", "–", "—"]
        var changed = true
        while changed {
            changed = false
            while let last = title.last, trailingPunctuation.contains(last) {
                title.removeLast()
                changed = true
            }
            title = title.trimmingCharacters(in: .whitespaces)
            if title.lowercased().hasSuffix(" please") {
                title = String(title.dropLast(" please".count))
                changed = true
            }
        }
        while let first = title.first, trailingPunctuation.contains(first) {
            title.removeFirst()
        }
        title = title.trimmingCharacters(in: .whitespaces)

        if strippingLeadingArticle {
            for article in ["a ", "an ", "the "] where title.lowercased().hasPrefix(article) {
                title = String(title.dropFirst(article.count))
                break
            }
        }

        if title.count > titleMaxChars {
            title = TitleDeriver.truncateAtWordBoundary(title, limit: titleMaxChars)
        }
        guard !title.isEmpty else { return nil }
        return title.prefix(1).uppercased() + title.dropFirst()
    }

    /// Rebuilds the string with the given (non-overlapping) ranges removed.
    nonisolated static func removing(ranges: [Range<String.Index>], from text: String) -> String {
        var result = ""
        var cursor = text.startIndex
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if cursor < range.lowerBound {
                result += text[cursor..<range.lowerBound]
            }
            cursor = max(cursor, range.upperBound)
        }
        if cursor < text.endIndex {
            result += text[cursor...]
        }
        return result
    }
}
