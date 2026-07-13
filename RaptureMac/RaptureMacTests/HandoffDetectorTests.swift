import XCTest
@testable import Rapture

/// Table tests for conservative deterministic handoff detection. The bar:
/// unambiguous reminder triggers and keyword-anchored appointments with an
/// explicit date AND time; everything else detects nothing and the note files.
final class HandoffDetectorTests: XCTestCase {

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

    private func detect(_ text: String, capturedAt: Date) -> [HandoffDetector.Candidate] {
        HandoffDetector.detect(text, capturedAt: capturedAt, timeZone: zone)
    }

    private func reminder(in candidates: [HandoffDetector.Candidate]) -> (title: String, due: HandoffDateParser.Resolved?)? {
        for case .reminder(let title, let due) in candidates { return (title, due) }
        return nil
    }

    private func event(in candidates: [HandoffDetector.Candidate]) -> (title: String, start: Date)? {
        for case .event(let title, let start) in candidates { return (title, start) }
        return nil
    }

    // MARK: - Reminder triggers

    func testRemindMeToWithDate() {
        let ref = date(2026, 7, 10, 15, 0)
        let r = reminder(in: detect("remind me to change the furnace filter Wednesday at 9am", capturedAt: ref))
        XCTAssertEqual(r?.title, "Change the furnace filter")
        XCTAssertEqual(r?.due?.date, date(2026, 7, 15, 9, 0))
        XCTAssertEqual(r?.due?.hasTime, true)
    }

    func testRememberTo() {
        let ref = date(2026, 7, 10, 15, 0)
        let r = reminder(in: detect("Remember to water the plants", capturedAt: ref))
        XCTAssertEqual(r?.title, "Water the plants")
        XCTAssertNil(r?.due, "no date stated → dateless reminder")
    }

    func testDontForgetCurlyApostrophe() {
        let ref = date(2026, 7, 10, 15, 0)
        let r = reminder(in: detect("Don’t forget the dry cleaning tomorrow", capturedAt: ref))
        XCTAssertEqual(r?.title, "The dry cleaning")
        XCTAssertEqual(r?.due?.date, date(2026, 7, 11))
        XCTAssertEqual(r?.due?.hasTime, false)
    }

    func testDontForgetStraightApostropheWithTo() {
        let ref = date(2026, 7, 10, 15, 0)
        let r = reminder(in: detect("don't forget to submit the invoice", capturedAt: ref))
        XCTAssertEqual(r?.title, "Submit the invoice")
    }

    func testMakeSureTo() {
        let ref = date(2026, 7, 10, 15, 0)
        let r = reminder(in: detect("make sure to renew the passport july 20", capturedAt: ref))
        XCTAssertEqual(r?.title, "Renew the passport")
        XCTAssertEqual(r?.due?.date, date(2026, 7, 20))
    }

    func testTriggerIsCaseInsensitive() {
        let ref = date(2026, 7, 10, 15, 0)
        XCTAssertNotNil(reminder(in: detect("REMIND ME TO stretch", capturedAt: ref)))
    }

    func testTriggerWithoutPayloadDetectsNothing() {
        let ref = date(2026, 7, 10, 15, 0)
        XCTAssertTrue(detect("remind me to", capturedAt: ref).isEmpty)
    }

    // MARK: - Events

    func testAppointmentWithDateAndTime() {
        // The PRD's Done-when example.
        let ref = date(2026, 7, 10, 15, 0)
        let e = event(in: detect("appointment at Quest at 1:10 tomorrow", capturedAt: ref))
        XCTAssertEqual(e?.title, "Appointment at Quest")
        XCTAssertEqual(e?.start, date(2026, 7, 11, 13, 10))
    }

    func testMeetingWithWeekdayAndBareHour() {
        let ref = date(2026, 7, 10, 15, 0)
        let e = event(in: detect("meeting with Sam Monday at 2", capturedAt: ref))
        XCTAssertEqual(e?.title, "Meeting with Sam")
        XCTAssertEqual(e?.start, date(2026, 7, 13, 14, 0))
    }

    func testCallWithMeridiem() {
        let ref = date(2026, 7, 10, 15, 0)
        let e = event(in: detect("call Friday 10am", capturedAt: ref))
        XCTAssertEqual(e?.title, "Call")
        XCTAssertEqual(e?.start, date(2026, 7, 17, 10, 0))
    }

    func testEventStripsLeadingArticle() {
        let ref = date(2026, 7, 10, 15, 0)
        let e = event(in: detect("a meeting with the plumber tomorrow at 8am", capturedAt: ref))
        XCTAssertEqual(e?.title, "Meeting with the plumber")
    }

    func testEventWithoutTimeDetectsNothing() {
        let ref = date(2026, 7, 10, 15, 0)
        XCTAssertTrue(detect("meeting with Sam tomorrow", capturedAt: ref).isEmpty)
    }

    func testEventWithoutDateDetectsNothing() {
        // Time-only resolves to the reference day, but an event needs an
        // explicitly stated day — "call at 2" alone is ambiguous.
        let ref = date(2026, 7, 10, 8, 0)
        XCTAssertTrue(detect("call at 2", capturedAt: ref).isEmpty)
    }

    func testEventWithoutKeywordDetectsNothing() {
        let ref = date(2026, 7, 10, 15, 0)
        XCTAssertTrue(detect("Quest tomorrow at 1:10", capturedAt: ref).isEmpty)
    }

    // MARK: - Precedence

    func testReminderTriggerWinsOverAppointmentSemantics() {
        // Locked decision: an explicit "remind me…" imperative always creates a
        // Reminder, never an event, even when the clause has keyword+date+time.
        let ref = date(2026, 7, 10, 15, 0)
        let candidates = detect("remind me to call John tomorrow at 2", capturedAt: ref)
        XCTAssertNil(event(in: candidates))
        let r = reminder(in: candidates)
        XCTAssertEqual(r?.title, "Call John")
        XCTAssertEqual(r?.due?.date, date(2026, 7, 11, 14, 0))
    }

    // MARK: - Clauses

    func testEmbeddedClauseInLongerNote() {
        let ref = date(2026, 7, 10, 15, 0)
        let text = "Had a good talk with the contractor about the deck. Remind me to send him the survey tomorrow. The permit question is still open."
        let candidates = detect(text, capturedAt: ref)
        XCTAssertEqual(candidates.count, 1)
        let r = reminder(in: candidates)
        XCTAssertEqual(r?.title, "Send him the survey")
        XCTAssertEqual(r?.due?.date, date(2026, 7, 11))
    }

    func testFirstOfEachKindWins() {
        let ref = date(2026, 7, 10, 15, 0)
        let text = "Remind me to buy stamps. Remind me to mail the letter. Meeting with Sam Monday at 2. Appointment at Quest tomorrow at 1:10."
        let candidates = detect(text, capturedAt: ref)
        XCTAssertEqual(candidates.count, 2, "at most one reminder and one event per note")
        XCTAssertEqual(reminder(in: candidates)?.title, "Buy stamps")
        XCTAssertEqual(event(in: candidates)?.title, "Meeting with Sam")
    }

    func testReminderAndEventFromSeparateClauses() {
        let ref = date(2026, 7, 10, 15, 0)
        let text = "Remind me to bring the folder. Meeting with legal Monday at 2."
        let candidates = detect(text, capturedAt: ref)
        XCTAssertEqual(candidates.count, 2)
    }

    // MARK: - Title cleanup

    func testTitleStripsTrailingPleaseAndPunctuation() {
        let ref = date(2026, 7, 10, 15, 0)
        let r = reminder(in: detect("remind me to take out the trash, please.", capturedAt: ref))
        XCTAssertEqual(r?.title, "Take out the trash")
    }

    func testTitleCollapsesWhitespaceAfterDateStripping() {
        let ref = date(2026, 7, 10, 15, 0)
        let r = reminder(in: detect("remind me to pick up the cake tomorrow from the bakery", capturedAt: ref))
        XCTAssertEqual(r?.title, "Pick up the cake from the bakery")
    }

    func testTitleCapsAtWordBoundary() {
        let ref = date(2026, 7, 10, 15, 0)
        let long = "remind me to review the quarterly financial projections spreadsheet for the northwest regional expansion project"
        let r = reminder(in: detect(long, capturedAt: ref))
        XCTAssertNotNil(r)
        XCTAssertLessThanOrEqual(r!.title.count, 60)
        XCTAssertFalse(r!.title.hasSuffix(" "))
    }

    func testDateAndBareHourStrippedFromTitle() {
        let ref = date(2026, 7, 10, 15, 0)
        let r = reminder(in: detect("remind me to call mom tomorrow at 6", capturedAt: ref))
        XCTAssertEqual(r?.title, "Call mom")
        XCTAssertEqual(r?.due?.date, date(2026, 7, 11, 18, 0))
    }

    // MARK: - Nothing detected

    func testPlainNoteDetectsNothing() {
        let ref = date(2026, 7, 10, 15, 0)
        XCTAssertTrue(detect("Rent is due on the 5th", capturedAt: ref).isEmpty)
        XCTAssertTrue(detect("great idea for the newsletter", capturedAt: ref).isEmpty)
        XCTAssertTrue(detect("https://youtube.com/watch?v=abc123", capturedAt: ref).isEmpty)
    }

    func testEmptyTextDetectsNothing() {
        let ref = date(2026, 7, 10, 15, 0)
        XCTAssertTrue(detect("", capturedAt: ref).isEmpty)
        XCTAssertTrue(detect("   \n  ", capturedAt: ref).isEmpty)
    }
}
