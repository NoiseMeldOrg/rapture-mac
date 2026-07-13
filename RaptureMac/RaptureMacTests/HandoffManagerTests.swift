import XCTest
@testable import Rapture

/// HandoffManager orchestration against the fake EventKit client and an
/// isolated per-test support directory (the RelayProcessorTests pattern).
final class HandoffManagerTests: XCTestCase {

    private var root: URL!
    private var appState: AppState!
    private var fake: FakeEventKitClient!
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

    @MainActor
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-mgr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fake = FakeEventKitClient()
        appState = AppState(supportDirectory: root, eventKit: fake)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @MainActor
    private func makeManager(now: Date) -> HandoffManager {
        HandoffManager(
            appState: appState,
            client: fake,
            ledger: HandoffLedger(stateStore: appState.state, clock: { now }),
            clock: { now },
            timeZoneProvider: { [zone] in zone }
        )
    }

    @MainActor
    private func enable(reminders: Bool, calendar: Bool) {
        appState.settings.update {
            $0.remindersHandoffEnabled = reminders
            $0.calendarHandoffEnabled = calendar
        }
    }

    // MARK: - Toggle gating

    @MainActor
    func testBothTogglesOffTouchesNothing() async {
        enable(reminders: false, calendar: false)
        let manager = makeManager(now: date(2026, 7, 10, 15, 0))
        let outcome = await manager.process(
            text: "remind me to call John tomorrow at 2",
            capturedAt: date(2026, 7, 10, 15, 0)
        )
        XCTAssertEqual(outcome, .none)
        XCTAssertTrue(fake.statusQueries.isEmpty, "toggles off must not even query auth status")
        XCTAssertTrue(fake.createdReminders.isEmpty)
        XCTAssertTrue(fake.createdEvents.isEmpty)
    }

    @MainActor
    func testPerKindToggleGating() async {
        enable(reminders: true, calendar: false)
        let capturedAt = date(2026, 7, 10, 15, 0)
        let manager = makeManager(now: capturedAt)
        let text = "Remind me to bring the folder. Meeting with legal Monday at 2."
        let outcome = await manager.process(text: text, capturedAt: capturedAt)
        XCTAssertTrue(outcome.reminderCreated)
        XCTAssertFalse(outcome.eventCreated, "calendar toggle off → the appointment clause is ignored")
        XCTAssertEqual(fake.createdReminders.count, 1)
        XCTAssertTrue(fake.createdEvents.isEmpty)
    }

    // MARK: - Creation details

    @MainActor
    func testReminderCarriesFullTextDueAndTargetList() async {
        enable(reminders: true, calendar: false)
        appState.settings.update { $0.remindersListID = "list-uuid" }
        let capturedAt = date(2026, 7, 10, 15, 0)
        let manager = makeManager(now: capturedAt)
        let text = "remind me to change the furnace filter Wednesday at 9am"
        let outcome = await manager.process(text: text, capturedAt: capturedAt)

        XCTAssertTrue(outcome.reminderCreated)
        let created = fake.createdReminders.first
        XCTAssertEqual(created?.title, "Change the furnace filter")
        XCTAssertEqual(created?.listID, "list-uuid")
        XCTAssertEqual(created?.due?.year, 2026)
        XCTAssertEqual(created?.due?.month, 7)
        XCTAssertEqual(created?.due?.day, 15)
        XCTAssertEqual(created?.due?.hour, 9)
        XCTAssertEqual(created?.due?.minute, 0)
        XCTAssertTrue(created?.notes.contains(text) ?? false, "notes must carry the full original dictation")
        XCTAssertTrue(created?.notes.contains("Captured via Rapture") ?? false)
    }

    @MainActor
    func testDateOnlyReminderGetsAllDayComponents() async {
        enable(reminders: true, calendar: false)
        let capturedAt = date(2026, 7, 10, 15, 0)
        let manager = makeManager(now: capturedAt)
        _ = await manager.process(text: "don't forget the dry cleaning tomorrow", capturedAt: capturedAt)
        let due = fake.createdReminders.first?.due
        XCTAssertEqual(due?.day, 11)
        XCTAssertNil(due?.hour, "date-only due must not fabricate a time")
    }

    @MainActor
    func testDatelessReminderHasNilDue() async {
        enable(reminders: true, calendar: false)
        let capturedAt = date(2026, 7, 10, 15, 0)
        let manager = makeManager(now: capturedAt)
        _ = await manager.process(text: "remember to water the plants", capturedAt: capturedAt)
        XCTAssertEqual(fake.createdReminders.count, 1)
        XCTAssertNil(fake.createdReminders.first?.due)
    }

    @MainActor
    func testEventGetsOneHourDurationAndTargetCalendar() async {
        enable(reminders: false, calendar: true)
        appState.settings.update { $0.calendarID = "cal-uuid" }
        let capturedAt = date(2026, 7, 10, 15, 0)
        let manager = makeManager(now: capturedAt)
        let outcome = await manager.process(text: "appointment at Quest at 1:10 tomorrow", capturedAt: capturedAt)

        XCTAssertTrue(outcome.eventCreated)
        let created = fake.createdEvents.first
        XCTAssertEqual(created?.title, "Appointment at Quest")
        XCTAssertEqual(created?.start, date(2026, 7, 11, 13, 10))
        XCTAssertEqual(created?.end, date(2026, 7, 11, 14, 10))
        XCTAssertEqual(created?.calendarID, "cal-uuid")
    }

    // MARK: - Past handling

    @MainActor
    func testPastEventSkippedButPastDueReminderCreates() async {
        enable(reminders: true, calendar: true)
        // Captured a week ago; flushed/triaged today — the appointment already
        // happened, the reminder is merely overdue.
        let capturedAt = date(2026, 7, 3, 9, 0)
        let now = date(2026, 7, 10, 15, 0)
        let manager = makeManager(now: now)

        let eventOutcome = await manager.process(
            text: "meeting with Sam Monday at 2", capturedAt: capturedAt
        )
        XCTAssertFalse(eventOutcome.eventCreated, "start (Jul 6) is before now (Jul 10) → skip")
        XCTAssertTrue(fake.createdEvents.isEmpty)

        let reminderOutcome = await manager.process(
            text: "remind me to submit the invoice Monday at 2", capturedAt: capturedAt
        )
        XCTAssertTrue(reminderOutcome.reminderCreated, "past-due reminders still create — overdue is actionable")
        XCTAssertEqual(fake.createdReminders.first?.due?.day, 6)
    }

    // MARK: - Dedup

    @MainActor
    func testReDictationWithinWindowDoesNotDoubleCreate() async {
        enable(reminders: true, calendar: true)
        let capturedAt = date(2026, 7, 10, 15, 0)
        let manager = makeManager(now: capturedAt)
        let text = "Remind me to bring the folder. Appointment at Quest at 1:10 tomorrow."

        let first = await manager.process(text: text, capturedAt: capturedAt)
        XCTAssertTrue(first.reminderCreated)
        XCTAssertTrue(first.eventCreated)

        let second = await manager.process(text: text, capturedAt: date(2026, 7, 10, 18, 0))
        XCTAssertEqual(second, .none, "re-dictation inside the ledger window must not double-create")
        XCTAssertEqual(fake.createdReminders.count, 1)
        XCTAssertEqual(fake.createdEvents.count, 1)
    }

    @MainActor
    func testLedgerSurvivesManagerRestart() async {
        enable(reminders: true, calendar: false)
        let capturedAt = date(2026, 7, 10, 15, 0)
        _ = await makeManager(now: capturedAt).process(text: "remember to water the plants", capturedAt: capturedAt)
        // A new manager over the same StateStore (app restart) still dedups.
        _ = await makeManager(now: date(2026, 7, 10, 16, 0)).process(text: "remember to water the plants", capturedAt: capturedAt)
        XCTAssertEqual(fake.createdReminders.count, 1)
    }

    // MARK: - Auth and errors

    @MainActor
    func testRevokedGrantReportsOnceAndCreatesNothing() async {
        enable(reminders: true, calendar: false)
        fake.statuses[.reminder] = .denied
        let capturedAt = date(2026, 7, 10, 15, 0)
        let manager = makeManager(now: capturedAt)

        _ = await manager.process(text: "remember to water the plants", capturedAt: capturedAt)
        XCTAssertTrue(fake.createdReminders.isEmpty)
        XCTAssertNotNil(appState.handoffLastError)

        appState.handoffLastError = nil
        _ = await manager.process(text: "remember to feed the cat", capturedAt: capturedAt)
        XCTAssertNil(appState.handoffLastError, "a revoked grant reports once per manager lifetime, not per capture")
    }

    @MainActor
    func testCreateFailureSurfacesErrorAndNeverThrows() async {
        enable(reminders: true, calendar: false)
        fake.failCreates = true
        let capturedAt = date(2026, 7, 10, 15, 0)
        let manager = makeManager(now: capturedAt)
        let outcome = await manager.process(text: "remember to water the plants", capturedAt: capturedAt)
        XCTAssertEqual(outcome, .none)
        XCTAssertNotNil(appState.handoffLastError)
    }

    @MainActor
    func testFailedCreateIsNotRecordedInLedger() async {
        enable(reminders: true, calendar: false)
        fake.failCreates = true
        let capturedAt = date(2026, 7, 10, 15, 0)
        let manager = makeManager(now: capturedAt)
        _ = await manager.process(text: "remember to water the plants", capturedAt: capturedAt)

        // The transient failure passes; the same dictation must now create.
        fake.failCreates = false
        let outcome = await manager.process(text: "remember to water the plants", capturedAt: capturedAt)
        XCTAssertTrue(outcome.reminderCreated, "a failed create must not poison the dedup ledger")
    }

    // MARK: - No detection

    @MainActor
    func testPlainNoteProducesNoHandoff() async {
        enable(reminders: true, calendar: true)
        let capturedAt = date(2026, 7, 10, 15, 0)
        let manager = makeManager(now: capturedAt)
        let outcome = await manager.process(text: "great idea for the newsletter", capturedAt: capturedAt)
        XCTAssertEqual(outcome, .none)
        XCTAssertTrue(fake.createdReminders.isEmpty)
        XCTAssertTrue(fake.createdEvents.isEmpty)
    }
}
