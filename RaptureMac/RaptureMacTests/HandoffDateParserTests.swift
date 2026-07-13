import XCTest
@testable import Rapture

/// Table tests for the deterministic date/time grammar. Everything anchors to a
/// fixed `reference` (the capture's own timestamp) in a fixed zone — including
/// references in the past, which is the backlog/spool-flush correctness case
/// NSDataDetector cannot handle.
final class HandoffDateParserTests: XCTestCase {

    private let zone = TimeZone(identifier: "America/New_York")!

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    /// 2026-07-10 is a Friday.
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute
        return calendar.date(from: comps)!
    }

    private func parse(_ clause: String, reference: Date) -> HandoffDateParser.Resolved? {
        HandoffDateParser.parse(in: clause, reference: reference, timeZone: zone)
    }

    // MARK: - Relative day words

    func testToday() {
        let ref = date(2026, 7, 10, 15, 0)  // Friday 3pm
        let r = parse("do the thing today", reference: ref)
        XCTAssertEqual(r?.date, date(2026, 7, 10))
        XCTAssertEqual(r?.hasTime, false)
    }

    func testTomorrow() {
        let ref = date(2026, 7, 10, 15, 0)
        let r = parse("pick up the package tomorrow", reference: ref)
        XCTAssertEqual(r?.date, date(2026, 7, 11))
        XCTAssertEqual(r?.hasTime, false)
    }

    func testTomorrowAnchorsToPastReferenceNotProcessingTime() {
        // Captured Friday June 5, triaged whenever: "tomorrow" is June 6.
        let ref = date(2026, 6, 5, 9, 0)
        let r = parse("call the plumber tomorrow", reference: ref)
        XCTAssertEqual(r?.date, date(2026, 6, 6))
    }

    // MARK: - Weekdays

    func testWeekdayResolvesToNextOccurrence() {
        let ref = date(2026, 7, 10, 15, 0)  // Friday
        let r = parse("wednesday at 9am", reference: ref)
        XCTAssertEqual(r?.date, date(2026, 7, 15, 9, 0))
        XCTAssertEqual(r?.hasTime, true)
    }

    func testSameWeekdayWithLaterTimeMeansToday() {
        let ref = date(2026, 7, 15, 8, 0)  // Wednesday 8am
        let r = parse("wednesday at 9am", reference: ref)
        XCTAssertEqual(r?.date, date(2026, 7, 15, 9, 0), "dictating 'Wednesday at 9am' on Wednesday 8am means today")
    }

    func testSameWeekdayWithEarlierTimeMeansNextWeek() {
        let ref = date(2026, 7, 15, 10, 0)  // Wednesday 10am
        let r = parse("wednesday at 9am", reference: ref)
        XCTAssertEqual(r?.date, date(2026, 7, 22, 9, 0))
    }

    func testSameWeekdayWithoutTimeMeansNextWeek() {
        let ref = date(2026, 7, 15, 10, 0)  // Wednesday
        let r = parse("do it wednesday", reference: ref)
        XCTAssertEqual(r?.date, date(2026, 7, 22))
        XCTAssertEqual(r?.hasTime, false)
    }

    func testNextWeekdayTreatedAsBareWeekday() {
        let ref = date(2026, 7, 10, 15, 0)  // Friday
        let r = parse("next monday", reference: ref)
        XCTAssertEqual(r?.date, date(2026, 7, 13))
    }

    func testWeekdayIsCaseInsensitive() {
        let ref = date(2026, 7, 10, 15, 0)
        let r = parse("Meeting Monday at 2", reference: ref)
        XCTAssertEqual(r?.date, date(2026, 7, 13, 14, 0))
    }

    // MARK: - Month + day

    func testMonthDayThisYear() {
        let ref = date(2026, 7, 10, 15, 0)
        let r = parse("dentist july 20", reference: ref)
        XCTAssertEqual(r?.date, date(2026, 7, 20))
    }

    func testMonthDayRollsToNextYearWhenPast() {
        let ref = date(2026, 7, 10, 15, 0)
        let r = parse("renew on july 5", reference: ref)
        XCTAssertEqual(r?.date, date(2027, 7, 5))
    }

    func testMonthAbbreviationAndOrdinal() {
        let ref = date(2026, 7, 10, 15, 0)
        let r = parse("due jan 5th", reference: ref)
        XCTAssertEqual(r?.date, date(2027, 1, 5))
    }

    func testMonthDaySameDayAsReferenceIsToday() {
        let ref = date(2026, 7, 10, 15, 0)
        let r = parse("july 10", reference: ref)
        XCTAssertEqual(r?.date, date(2026, 7, 10))
    }

    func testInvalidMonthDayReturnsNil() {
        let ref = date(2026, 7, 10, 15, 0)
        XCTAssertNil(parse("february 30", reference: ref))
    }

    // MARK: - Time forms

    func testMeridiemTime() {
        let ref = date(2026, 7, 10, 15, 0)
        let r = parse("tomorrow at 9:30pm", reference: ref)
        XCTAssertEqual(r?.date, date(2026, 7, 11, 21, 30))
    }

    func testMeridiemWithSpace() {
        let ref = date(2026, 7, 10, 8, 0)
        let r = parse("today at 9 am", reference: ref)
        XCTAssertEqual(r?.date, date(2026, 7, 10, 9, 0))
    }

    func testDottedMeridiemWithClauseStrippedFinalDot() {
        // Clause splitting on sentence punctuation eats the final dot of "a.m."
        let ref = date(2026, 7, 10, 8, 0)
        let r = parse("dentist tomorrow at 9 a.m", reference: ref)
        XCTAssertEqual(r?.date, date(2026, 7, 11, 9, 0))
    }

    func testTwelveAMIsMidnight() {
        let ref = date(2026, 7, 10, 15, 0)
        let r = parse("tomorrow at 12am", reference: ref)
        XCTAssertEqual(r?.date, date(2026, 7, 11, 0, 0))
    }

    func testColonTimeWithoutMeridiemAfternoonBand() {
        // The PRD's own example: "appointment at Quest at 1:10 tomorrow" → 13:10.
        let ref = date(2026, 7, 10, 15, 0)
        let r = parse("at 1:10 tomorrow", reference: ref)
        XCTAssertEqual(r?.date, date(2026, 7, 11, 13, 10))
    }

    func testColonTimeMorningBand() {
        let ref = date(2026, 7, 10, 15, 0)
        let r = parse("tomorrow at 9:15", reference: ref)
        XCTAssertEqual(r?.date, date(2026, 7, 11, 9, 15))
    }

    func testTwentyFourHourTimeVerbatim() {
        let ref = date(2026, 7, 10, 15, 0)
        let r = parse("tomorrow at 13:30", reference: ref)
        XCTAssertEqual(r?.date, date(2026, 7, 11, 13, 30))
    }

    func testBareHourAfternoonBand() {
        let ref = date(2026, 7, 10, 15, 0)
        let r = parse("meeting monday at 2", reference: ref)
        XCTAssertEqual(r?.date, date(2026, 7, 13, 14, 0))
    }

    func testBareHourNoonBand() {
        let ref = date(2026, 7, 10, 15, 0)
        let r = parse("lunch tomorrow at 12", reference: ref)
        XCTAssertEqual(r?.date, date(2026, 7, 11, 12, 0))
    }

    func testBareNumberWithoutAtIsNotATime() {
        let ref = date(2026, 7, 10, 15, 0)
        XCTAssertNil(parse("buy 2 dozen eggs", reference: ref))
    }

    func testInvalidMinutesYieldNoTime() {
        let ref = date(2026, 7, 10, 15, 0)
        let r = parse("tomorrow at 1:75", reference: ref)
        // The malformed time is ignored entirely — the date still parses.
        XCTAssertEqual(r?.date, date(2026, 7, 11))
        XCTAssertEqual(r?.hasTime, false)
    }

    // MARK: - Time-only

    func testTimeOnlyLaterTodayStaysToday() {
        let ref = date(2026, 7, 10, 8, 0)
        let r = parse("remind me at 5", reference: ref)  // 5 → 17:00, after 8am
        XCTAssertEqual(r?.date, date(2026, 7, 10, 17, 0))
        XCTAssertEqual(r?.hasTime, true)
    }

    func testTimeOnlyAlreadyPassedRollsToTomorrow() {
        let ref = date(2026, 7, 10, 18, 0)  // 6pm
        let r = parse("remind me at 5", reference: ref)  // 17:00 ≤ 18:00 → tomorrow
        XCTAssertEqual(r?.date, date(2026, 7, 11, 17, 0))
    }

    // MARK: - Ambiguity → nil

    func testAmbiguousPhrasesReturnNil() {
        let ref = date(2026, 7, 10, 15, 0)
        for clause in ["next week", "soon", "in 20 minutes", "this weekend", "sometime", "later"] {
            XCTAssertNil(parse(clause, reference: ref), "'\(clause)' must not parse")
        }
    }

    func testPlainTextReturnsNil() {
        let ref = date(2026, 7, 10, 15, 0)
        XCTAssertNil(parse("change the furnace filter", reference: ref))
    }

    // MARK: - Consumed ranges (title stripping)

    func testConsumedRangesCoverDateAndTimeTokens() {
        let ref = date(2026, 7, 10, 15, 0)
        let clause = "appointment at Quest at 1:10 tomorrow"
        let r = parse(clause, reference: ref)
        let consumed = r?.consumedRanges.map { String(clause[$0]) } ?? []
        XCTAssertEqual(Set(consumed), Set(["at 1:10", "tomorrow"]))
    }

    func testConsumedRangeIncludesNextPrefix() {
        let ref = date(2026, 7, 10, 15, 0)
        let clause = "review the deck next monday"
        let r = parse(clause, reference: ref)
        let consumed = r?.consumedRanges.map { String(clause[$0]) } ?? []
        XCTAssertEqual(consumed, ["next monday"])
    }

    func testConsumedRangeCoversMeridiemForm() {
        let ref = date(2026, 7, 10, 15, 0)
        let clause = "change the furnace filter Wednesday at 9am"
        let r = parse(clause, reference: ref)
        XCTAssertEqual(r?.date, date(2026, 7, 15, 9, 0))
        let consumed = r?.consumedRanges.map { String(clause[$0]) } ?? []
        XCTAssertEqual(Set(consumed), Set(["Wednesday", "at 9am"]))
    }
}
