import Foundation

/// Mechanical validation of an engine draft. Everything a model can get wrong
/// is checked here, per field: a bad field is discarded (its deterministic
/// fallback applies) while the rest of the result still counts. Pure and
/// table-tested — no engine, no I/O.
enum AITriageValidator {
    /// Formatted bodies outside [raw/2, raw*3/2] are rewrites, not "light
    /// formatting" — discard.
    nonisolated static let bodyLengthMin = 0.5
    nonisolated static let bodyLengthMax = 1.5
    nonisolated static let titleMaxWords = 10
    nonisolated static let titleMaxChars = 60

    nonisolated static func validate(
        draft: AIEngineDraft,
        rawText: String,
        truncated: Bool,
        capturedAt: Date,
        timeZone: TimeZone
    ) -> AITriageOutput {
        var output = AITriageOutput()

        output.classification = validClassification(draft.classification)
        output.title = validTitle(draft.title)
        output.formattedBody = validFormattedBody(draft.formattedBody, rawText: rawText, truncated: truncated)

        let validated = validHandoffs(draft.handoffs, rawText: rawText, timeZone: timeZone)
        output.handoffs = validated
        output.handoffsInvalidated = !draft.handoffs.isEmpty && validated.isEmpty

        return output
    }

    // MARK: - Per-field rules

    nonisolated static func validClassification(_ raw: String?) -> CaptureType? {
        switch raw?.lowercased() {
        case "task": return .task
        case "idea": return .idea
        case "journal": return .journal
        default: return nil
        }
    }

    /// Same sanitation the deterministic titles get (filesystem-hostile
    /// characters, leading dots), plus the 10-word / 60-char smart-title cap.
    nonisolated static func validTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var words = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        if words.count > titleMaxWords {
            words = Array(words.prefix(titleMaxWords))
        }
        var title = words.joined(separator: " ")
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: ":", with: " ")
        title = title
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        while title.hasPrefix(".") {
            title.removeFirst()
        }
        title = title.trimmingCharacters(in: .whitespaces)
        if title.count > titleMaxChars {
            title = TitleDeriver.truncateAtWordBoundary(title, limit: titleMaxChars)
        }
        guard !title.isEmpty else { return nil }
        return title.prefix(1).uppercased() + title.dropFirst()
    }

    nonisolated static func validFormattedBody(_ raw: String?, rawText: String, truncated: Bool) -> String? {
        // Never "format" text the model didn't fully see.
        guard !truncated, let raw else { return nil }
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        // Identical to the raw = no formatting happened; keep nil so compose
        // doesn't emit a redundant ## Raw section.
        guard body != rawText.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let rawCount = Double(rawText.count)
        let bodyCount = Double(body.count)
        guard rawCount > 0,
              bodyCount >= rawCount * bodyLengthMin,
              bodyCount <= rawCount * bodyLengthMax else { return nil }
        return body
    }

    /// Kind must parse; the clause must actually appear in the note (normalized
    /// containment — a fabricated clause is the tell of a hallucinated handoff);
    /// events need the full date+time; partial reminder dates degrade to
    /// dateless. Caps at one reminder + one event, first of each wins (the
    /// locked M3 bar).
    nonisolated static func validHandoffs(
        _ drafts: [AIEngineDraft.DraftHandoff],
        rawText: String,
        timeZone: TimeZone
    ) -> [HandoffDetector.Detected] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let normalizedRaw = normalizeForContainment(rawText)

        var reminder: HandoffDetector.Detected?
        var event: HandoffDetector.Detected?

        for draft in drafts {
            let clause = draft.clause.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clause.isEmpty,
                  normalizedRaw.contains(normalizeForContainment(clause)),
                  let title = HandoffDetector.cleanTitle(draft.title, strippingLeadingArticle: false)
            else { continue }

            switch draft.kind.lowercased() {
            case "reminder":
                guard reminder == nil else { continue }
                let due = reminderDue(from: draft, calendar: calendar)
                reminder = HandoffDetector.Detected(
                    candidate: .reminder(title: title, due: due),
                    clause: clause
                )
            case "event":
                guard event == nil else { continue }
                guard let start = eventStart(from: draft, calendar: calendar) else { continue }
                event = HandoffDetector.Detected(
                    candidate: .event(title: title, start: start),
                    clause: clause
                )
            default:
                continue
            }
        }
        return [reminder, event].compactMap { $0 }
    }

    // MARK: - Date materialization

    /// Full date (+ optional time) → timed/date-only due; anything partial →
    /// dateless (the conservative degradation, mirroring the deterministic
    /// parser's posture). An impossible date (Feb 30) → dateless.
    nonisolated static func reminderDue(
        from draft: AIEngineDraft.DraftHandoff,
        calendar: Calendar
    ) -> HandoffDateParser.Resolved? {
        guard let year = draft.year, let month = draft.month, let day = draft.day else { return nil }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        let hasTime = draft.hour != nil && draft.minute != nil
        if hasTime {
            comps.hour = draft.hour
            comps.minute = draft.minute
        }
        guard let date = strictDate(from: comps, calendar: calendar) else { return nil }
        return HandoffDateParser.Resolved(
            date: date,
            hasTime: hasTime,
            hasExplicitDay: true,
            consumedRanges: []
        )
    }

    nonisolated static func eventStart(
        from draft: AIEngineDraft.DraftHandoff,
        calendar: Calendar
    ) -> Date? {
        guard let year = draft.year, let month = draft.month, let day = draft.day,
              let hour = draft.hour, let minute = draft.minute else { return nil }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        return strictDate(from: comps, calendar: calendar)
    }

    /// `Calendar.date(from:)` happily rolls Feb 30 into March; a model that
    /// invents an impossible date must not create a silently-shifted item.
    private nonisolated static func strictDate(from comps: DateComponents, calendar: Calendar) -> Date? {
        guard let date = calendar.date(from: comps) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard roundTrip.year == comps.year,
              roundTrip.month == comps.month,
              roundTrip.day == comps.day,
              roundTrip.hour == (comps.hour ?? roundTrip.hour),
              roundTrip.minute == (comps.minute ?? roundTrip.minute) else { return nil }
        return date
    }

    /// Lowercased, whitespace-collapsed — tolerant of capitalization and
    /// spacing drift between the model's echo and the raw dictation, strict
    /// about the words themselves.
    nonisolated static func normalizeForContainment(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }
}
