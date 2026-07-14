import XCTest
@testable import Rapture

/// M4's handoff evolution: clause fingerprints, `detectDetailed`, and the
/// manager's AI-candidate merge with dual-fingerprint dedup (the M3-flagged
/// design point: AI titles vary, clauses don't).
final class HandoffAIMergeTests: XCTestCase {

    private var root: URL!
    private var appState: AppState!
    private var fake: FakeEventKitClient!
    private let zone = TimeZone(identifier: "America/New_York")!

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute
        return calendar.date(from: comps)!
    }

    @MainActor
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-ai-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fake = FakeEventKitClient()
        appState = AppState(supportDirectory: root, eventKit: fake)
        appState.settings.update {
            $0.remindersHandoffEnabled = true
            $0.calendarHandoffEnabled = true
        }
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

    // MARK: - Clause fingerprint (pure)

    func testClauseFingerprintNamespaceDisjointFromTitleFingerprint() {
        let title = HandoffLedger.fingerprint(kind: .reminder, title: "call john", dateKey: "none")
        let clause = HandoffLedger.clauseFingerprint(kind: .reminder, clause: "call john", dateKey: "none")
        XCTAssertNotEqual(title, clause)
        XCTAssertTrue(clause.contains("|clause|"))
    }

    func testClauseFingerprintNormalizesLikeTitles() {
        let a = HandoffLedger.clauseFingerprint(kind: .reminder, clause: "Remind me to  call John.", dateKey: "none")
        let b = HandoffLedger.clauseFingerprint(kind: .reminder, clause: "remind me to call john", dateKey: "none")
        XCTAssertEqual(a, b)
    }

    func testClauseFingerprintKeepsDatelessWindowRule() {
        let dateless = HandoffLedger.clauseFingerprint(kind: .reminder, clause: "call john", dateKey: HandoffLedger.datelessDateKey)
        XCTAssertEqual(HandoffLedger.window(forFingerprint: dateless), HandoffLedger.datelessWindow)
        let dated = HandoffLedger.clauseFingerprint(kind: .event, clause: "call john", dateKey: "2026-07-11T17:10:00Z")
        XCTAssertEqual(HandoffLedger.window(forFingerprint: dated), HandoffLedger.ttl)
    }

    // MARK: - detectDetailed

    func testDetectDetailedCarriesClauses() {
        let capturedAt = date(2026, 7, 10, 15, 0)
        let text = "remind me to water the plants tomorrow. Dentist appointment Monday at 9am."
        let detected = HandoffDetector.detectDetailed(text, capturedAt: capturedAt, timeZone: zone)
        XCTAssertEqual(detected.count, 2)
        XCTAssertEqual(detected.first?.clause, "remind me to water the plants tomorrow")
        XCTAssertEqual(detected.last?.clause, "Dentist appointment Monday at 9am")
        // The plain detect wrapper stays behavior-identical.
        XCTAssertEqual(
            HandoffDetector.detect(text, capturedAt: capturedAt, timeZone: zone),
            detected.map(\.candidate)
        )
    }

    // MARK: - Candidate source selection (pure)

    func testNilAIUsesDeterministicDetector() {
        let capturedAt = date(2026, 7, 10, 15, 0)
        let result = HandoffManager.candidates(
            text: "remind me to water the plants", capturedAt: capturedAt, timeZone: zone, ai: nil
        )
        XCTAssertEqual(result.count, 1)
    }

    func testInvalidatedAIFallsBackToDeterministicDetector() {
        let capturedAt = date(2026, 7, 10, 15, 0)
        var ai = AITriageOutput()
        ai.handoffsInvalidated = true
        let result = HandoffManager.candidates(
            text: "remind me to water the plants", capturedAt: capturedAt, timeZone: zone, ai: ai
        )
        XCTAssertEqual(result.count, 1, "a garbage AI handoff block must not disable M3 behavior")
    }

    func testValidAICandidatesReplaceDetectorOutput() {
        let capturedAt = date(2026, 7, 10, 15, 0)
        var ai = AITriageOutput()
        ai.handoffs = [HandoffDetector.Detected(
            candidate: .reminder(title: "Call mom", due: nil),
            clause: "remind me at some point to call mom"
        )]
        let result = HandoffManager.candidates(
            text: "remind me to water the plants", capturedAt: capturedAt, timeZone: zone, ai: ai
        )
        XCTAssertEqual(result, ai.handoffs)
    }

    func testValidEmptyAIListIsTrusted() {
        let capturedAt = date(2026, 7, 10, 15, 0)
        let ai = AITriageOutput() // no handoffs, not invalidated
        let result = HandoffManager.candidates(
            text: "remind me to water the plants", capturedAt: capturedAt, timeZone: zone, ai: ai
        )
        XCTAssertTrue(result.isEmpty, "AI confidently found none — superset assumption")
    }

    // MARK: - Cross-path dedup (the flagged design point)

    @MainActor
    func testDeterministicThenAIRedictationDoesNotDoubleCreate() async {
        let now = date(2026, 7, 10, 15, 0)
        let manager = makeManager(now: now)
        let clause = "remind me to change the furnace filter Wednesday at 9am"

        // Day 1: deterministic path (AI off) creates from the mechanical title.
        let first = await manager.process(text: clause, capturedAt: now, ai: nil)
        XCTAssertTrue(first.reminderCreated)
        XCTAssertEqual(fake.createdReminders.count, 1)

        // Day 1 later: AI ON re-dictation of the same utterance — different
        // smart title, same clause → clause fingerprint suppresses.
        var ai = AITriageOutput()
        ai.handoffs = [HandoffDetector.Detected(
            candidate: .reminder(
                title: "Replace furnace air filter",
                due: HandoffDateParser.parse(in: "Wednesday at 9am", reference: now, timeZone: zone)
            ),
            clause: clause
        )]
        let second = await manager.process(text: clause, capturedAt: now, ai: ai)
        XCTAssertFalse(second.reminderCreated, "same clause + same due must not double-create across tiers")
        XCTAssertEqual(fake.createdReminders.count, 1)
    }

    @MainActor
    func testAIThenDeterministicRedictationDoesNotDoubleCreate() async {
        let now = date(2026, 7, 10, 15, 0)
        let manager = makeManager(now: now)
        let clause = "remind me to change the furnace filter Wednesday at 9am"

        // Day 1: AI creates with a smart title.
        var ai = AITriageOutput()
        ai.handoffs = [HandoffDetector.Detected(
            candidate: .reminder(
                title: "Replace furnace air filter",
                due: HandoffDateParser.parse(in: "Wednesday at 9am", reference: now, timeZone: zone)
            ),
            clause: clause
        )]
        let first = await manager.process(text: clause, capturedAt: now, ai: ai)
        XCTAssertTrue(first.reminderCreated)

        // Later: AI unavailable — deterministic path sees the same clause.
        let second = await manager.process(text: clause, capturedAt: now, ai: nil)
        XCTAssertFalse(second.reminderCreated)
        XCTAssertEqual(fake.createdReminders.count, 1)
    }

    @MainActor
    func testAIEventGoesThroughSharedGates() async {
        let now = date(2026, 7, 10, 15, 0)
        let manager = makeManager(now: now)

        // Past-dated AI event is skipped by the shared past-skip gate.
        var pastAI = AITriageOutput()
        pastAI.handoffs = [HandoffDetector.Detected(
            candidate: .event(title: "Old meeting", start: date(2026, 7, 9, 10, 0)),
            clause: "meeting yesterday at 10"
        )]
        let past = await manager.process(text: "meeting yesterday at 10", capturedAt: now, ai: pastAI)
        XCTAssertFalse(past.eventCreated)
        XCTAssertTrue(fake.createdEvents.isEmpty)

        // Future AI event creates with the notes-field contract intact.
        var futureAI = AITriageOutput()
        futureAI.handoffs = [HandoffDetector.Detected(
            candidate: .event(title: "Quest lab draw", start: date(2026, 7, 11, 13, 10)),
            clause: "appointment at Quest at 1:10 tomorrow"
        )]
        let text = "appointment at Quest at 1:10 tomorrow"
        let future = await manager.process(text: text, capturedAt: now, ai: futureAI)
        XCTAssertTrue(future.eventCreated)
        XCTAssertEqual(fake.createdEvents.count, 1)
        XCTAssertTrue(fake.createdEvents.first?.notes.contains(text) == true, "full dictation rides in the notes field")
    }
}
