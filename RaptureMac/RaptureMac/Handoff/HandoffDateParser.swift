import Foundation

/// Deterministic natural-date parsing for handoff detection, anchored to the
/// capture's own timestamp — never processing time: a note captured Friday
/// saying "tomorrow" means Saturday even if it triages Monday during backlog
/// catch-up or a spool flush. Hand-rolled because `NSDataDetector` cannot
/// anchor relative dates to a past reference. Conservative by design: anything
/// outside the grammar returns nil and the capture just files.
///
/// Grammar: `today` / `tomorrow` / full weekday names / `next <weekday>`
/// (treated as the bare weekday) / `<month> <day>` (full or 3-letter names,
/// optional ordinal). Times: `9am` / `9:30 pm` / `1:10` / `at 2` / `13:30`.
/// Meridiem-less hours disambiguate 1–6 → PM, 7–11 → AM, 12 → noon (locked
/// product decision — "at 1:10 tomorrow" means 13:10).
enum HandoffDateParser {
    struct Resolved: Equatable, Sendable {
        /// Absolute instant in the given zone. For date-only matches this is
        /// midnight of the resolved day; consult `hasTime` before using the clock.
        var date: Date
        var hasTime: Bool
        /// True when an explicit day token (today/tomorrow/weekday/month-day)
        /// was matched — false for time-only phrases, which resolve to the
        /// reference's day. Events require an explicit day AND a time.
        var hasExplicitDay: Bool
        /// Ranges of the matched date/time tokens in the original clause, for
        /// mechanical title stripping. Possibly non-contiguous ("Monday" … "at 2").
        var consumedRanges: [Range<String.Index>]
    }

    nonisolated static func parse(in clause: String, reference: Date, timeZone: TimeZone) -> Resolved? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let time = findTime(in: clause)
        let day = findDay(in: clause)

        switch (day, time) {
        case (nil, nil):
            return nil
        case (let d?, nil):
            guard let resolved = resolveDay(d, reference: reference, calendar: calendar, parsedTime: nil) else { return nil }
            return Resolved(date: resolved, hasTime: false, hasExplicitDay: true, consumedRanges: [d.range])
        case (nil, let t?):
            // Time-only: the reference's day at that time, rolled a day forward
            // when the moment has already passed ("remind me at 5" said at 6pm).
            var comps = calendar.dateComponents([.year, .month, .day], from: reference)
            comps.hour = t.hour
            comps.minute = t.minute
            guard var date = calendar.date(from: comps) else { return nil }
            if date <= reference {
                guard let rolled = calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
                date = rolled
            }
            return Resolved(date: date, hasTime: true, hasExplicitDay: false, consumedRanges: [t.range])
        case (let d?, let t?):
            guard let dayStart = resolveDay(d, reference: reference, calendar: calendar, parsedTime: t) else { return nil }
            var comps = calendar.dateComponents([.year, .month, .day], from: dayStart)
            comps.hour = t.hour
            comps.minute = t.minute
            guard let date = calendar.date(from: comps) else { return nil }
            let ranges = [d.range, t.range].sorted { $0.lowerBound < $1.lowerBound }
            return Resolved(date: date, hasTime: true, hasExplicitDay: true, consumedRanges: ranges)
        }
    }

    // MARK: - Time matching

    struct ParsedTime: Equatable, Sendable {
        var hour: Int
        var minute: Int
        var range: Range<String.Index>
    }

    /// `at 9am`, `9:30 pm`, `9 a.m.` — the meridiem is authoritative. The dotted
    /// forms allow a missing final dot (clause splitting on sentence punctuation
    /// eats it), and the tail is a lookahead rather than `\b` because `\b` never
    /// matches between a trailing `.` and whitespace.
    private nonisolated static let meridiemTime = try! NSRegularExpression(
        pattern: #"\b(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(a\.m\.?|p\.m\.?|am|pm)(?![A-Za-z])"#,
        options: [.caseInsensitive]
    )
    /// `1:10`, `at 13:30` — no meridiem; banded or 24-hour verbatim.
    private nonisolated static let colonTime = try! NSRegularExpression(
        pattern: #"\b(?:at\s+)?(\d{1,2}):(\d{2})\b"#,
        options: [.caseInsensitive]
    )
    /// `at 2` — the bare hour requires "at" so ordinary counts ("buy 2 dozen
    /// eggs") never read as times.
    private nonisolated static let bareHour = try! NSRegularExpression(
        pattern: #"\bat\s+(\d{1,2})\b"#,
        options: [.caseInsensitive]
    )

    nonisolated static func findTime(in clause: String) -> ParsedTime? {
        let ns = clause as NSString
        let full = NSRange(location: 0, length: ns.length)

        // Priority: meridiem > H:MM > bare "at N". Within a pattern the last
        // occurrence wins (date/time phrases trail the payload in dictation).
        // A matched-but-invalid time (minute 75) yields no time at all rather
        // than falling through to a misparse of the same token.
        if let m = meridiemTime.matches(in: clause, range: full).last {
            guard let hour = int(ns, m.range(at: 1)), (1...12).contains(hour),
                  let range = Range(m.range, in: clause) else { return nil }
            let minute = int(ns, m.range(at: 2)) ?? 0
            guard (0...59).contains(minute) else { return nil }
            let meridiem = ns.substring(with: m.range(at: 3)).lowercased()
            let isPM = meridiem.hasPrefix("p")
            let hour24 = isPM ? (hour == 12 ? 12 : hour + 12) : (hour == 12 ? 0 : hour)
            return ParsedTime(hour: hour24, minute: minute, range: range)
        }
        if let m = colonTime.matches(in: clause, range: full).last {
            guard let hour = int(ns, m.range(at: 1)), let minute = int(ns, m.range(at: 2)),
                  (0...59).contains(minute), let hour24 = unqualifiedHour24(hour),
                  let range = Range(m.range, in: clause) else { return nil }
            return ParsedTime(hour: hour24, minute: minute, range: range)
        }
        if let m = bareHour.matches(in: clause, range: full).last {
            guard let hour = int(ns, m.range(at: 1)), let hour24 = unqualifiedHour24(hour),
                  let range = Range(m.range, in: clause) else { return nil }
            return ParsedTime(hour: hour24, minute: 0, range: range)
        }
        return nil
    }

    /// Meridiem-less disambiguation (locked): 1–6 → PM, 7–11 → AM, 12 → noon;
    /// 13–23 are spoken 24-hour and taken verbatim.
    nonisolated static func unqualifiedHour24(_ hour: Int) -> Int? {
        switch hour {
        case 13...23: return hour
        case 12: return 12
        case 7...11: return hour
        case 1...6: return hour + 12
        case 0: return 0
        default: return nil
        }
    }

    // MARK: - Day matching

    struct ParsedDay: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case today
            case tomorrow
            case weekday(Int)          // Calendar weekday: 1 = Sunday … 7 = Saturday
            case monthDay(month: Int, day: Int)
        }
        var kind: Kind
        var range: Range<String.Index>
    }

    private nonisolated static let relativeDay = try! NSRegularExpression(
        pattern: #"\b(today|tomorrow)\b"#, options: [.caseInsensitive]
    )
    /// "next monday" resolves identically to "monday" (locked: near-term
    /// dictation dominates and off-by-a-week is the worse error); the range
    /// still covers the "next " prefix so title stripping is clean.
    private nonisolated static let weekdayName = try! NSRegularExpression(
        pattern: #"\b(?:next\s+)?(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#,
        options: [.caseInsensitive]
    )
    private nonisolated static let monthDay = try! NSRegularExpression(
        pattern: #"\b(january|jan|february|feb|march|mar|april|apr|may|june|jun|july|jul|august|aug|september|sept|sep|october|oct|november|nov|december|dec)\s+(\d{1,2})(?:st|nd|rd|th)?\b"#,
        options: [.caseInsensitive]
    )

    private nonisolated static let weekdayIndex: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
        "thursday": 5, "friday": 6, "saturday": 7,
    ]
    private nonisolated static let monthIndex: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3,
        "april": 4, "apr": 4, "may": 5, "june": 6, "jun": 6, "july": 7, "jul": 7,
        "august": 8, "aug": 8, "september": 9, "sept": 9, "sep": 9,
        "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12,
    ]

    nonisolated static func findDay(in clause: String) -> ParsedDay? {
        let ns = clause as NSString
        let full = NSRange(location: 0, length: ns.length)
        var candidates: [ParsedDay] = []

        if let m = relativeDay.matches(in: clause, range: full).last,
           let range = Range(m.range, in: clause) {
            let word = ns.substring(with: m.range(at: 1)).lowercased()
            candidates.append(ParsedDay(kind: word == "today" ? .today : .tomorrow, range: range))
        }
        if let m = weekdayName.matches(in: clause, range: full).last,
           let range = Range(m.range, in: clause),
           let index = weekdayIndex[ns.substring(with: m.range(at: 1)).lowercased()] {
            candidates.append(ParsedDay(kind: .weekday(index), range: range))
        }
        if let m = monthDay.matches(in: clause, range: full).last,
           let range = Range(m.range, in: clause),
           let month = monthIndex[ns.substring(with: m.range(at: 1)).lowercased()],
           let day = int(ns, m.range(at: 2)) {
            candidates.append(ParsedDay(kind: .monthDay(month: month, day: day), range: range))
        }

        // The last-positioned token wins (trailing-phrase convention).
        return candidates.max { $0.range.lowerBound < $1.range.lowerBound }
    }

    private nonisolated static func resolveDay(
        _ day: ParsedDay,
        reference: Date,
        calendar: Calendar,
        parsedTime: ParsedTime?
    ) -> Date? {
        let refStart = calendar.startOfDay(for: reference)
        switch day.kind {
        case .today:
            return refStart
        case .tomorrow:
            return calendar.date(byAdding: .day, value: 1, to: refStart)
        case .weekday(let target):
            let refWeekday = calendar.component(.weekday, from: reference)
            var delta = (target - refWeekday + 7) % 7
            if delta == 0 {
                // Same weekday as the reference: today only when the stated
                // time is still ahead ("Wednesday at 9am" said Wednesday 8am);
                // otherwise — or with no time at all — it means next week.
                if let t = parsedTime {
                    let ref = calendar.dateComponents([.hour, .minute], from: reference)
                    let refMinutes = (ref.hour ?? 0) * 60 + (ref.minute ?? 0)
                    if t.hour * 60 + t.minute <= refMinutes { delta = 7 }
                } else {
                    delta = 7
                }
            }
            return calendar.date(byAdding: .day, value: delta, to: refStart)
        case .monthDay(let month, let day):
            let refYear = calendar.component(.year, from: reference)
            for year in [refYear, refYear + 1] {
                var comps = DateComponents()
                comps.year = year
                comps.month = month
                comps.day = day
                // Calendar.date(from:) rolls invalid dates (Feb 30 → Mar 2);
                // round-trip to reject them instead.
                guard let candidate = calendar.date(from: comps),
                      calendar.component(.month, from: candidate) == month,
                      calendar.component(.day, from: candidate) == day else { return nil }
                if candidate >= refStart { return candidate }
            }
            return nil
        }
    }

    private nonisolated static func int(_ ns: NSString, _ range: NSRange) -> Int? {
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        return Int(ns.substring(with: range))
    }
}
