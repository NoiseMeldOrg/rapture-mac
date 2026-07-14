import XCTest
@testable import Rapture

/// Table tests for the mechanical gate between engine drafts and trusted AI
/// output. Every rule the plan locked: per-field discard, clause containment,
/// strict date materialization, the 1+1 cap, and the invalidated flag.
final class AITriageValidatorTests: XCTestCase {

    private let zone = TimeZone(identifier: "America/New_York")!
    private let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func validate(
        _ draft: AIEngineDraft,
        rawText: String = "remind me to call John tomorrow at 2 about the invoice",
        truncated: Bool = false
    ) -> AITriageOutput {
        AITriageValidator.validate(
            draft: draft,
            rawText: rawText,
            truncated: truncated,
            capturedAt: capturedAt,
            timeZone: zone
        )
    }

    // MARK: - Classification

    func testClassificationAcceptsThreeClasses() {
        XCTAssertEqual(AITriageValidator.validClassification("task"), .task)
        XCTAssertEqual(AITriageValidator.validClassification("Idea"), .idea)
        XCTAssertEqual(AITriageValidator.validClassification("JOURNAL"), .journal)
    }

    func testClassificationRejectsEverythingElse() {
        XCTAssertNil(AITriageValidator.validClassification(nil))
        XCTAssertNil(AITriageValidator.validClassification(""))
        XCTAssertNil(AITriageValidator.validClassification("voice-note"))
        XCTAssertNil(AITriageValidator.validClassification("link"))
        XCTAssertNil(AITriageValidator.validClassification("tasks"))
        XCTAssertNil(AITriageValidator.validClassification("finance"))
    }

    // MARK: - Title

    func testTitleSanitizedAndCapitalized() {
        XCTAssertEqual(AITriageValidator.validTitle("fix the garage door sensor"), "Fix the garage door sensor")
    }

    func testTitleStripsFilesystemHostileCharacters() {
        XCTAssertEqual(AITriageValidator.validTitle("a/b: c"), "A b c")
    }

    func testTitleCapsAtTenWords() {
        let eleven = "one two three four five six seven eight nine ten eleven"
        XCTAssertEqual(AITriageValidator.validTitle(eleven), "One two three four five six seven eight nine ten")
    }

    func testTitleCapsAtSixtyCharsOnWordBoundary() {
        let long = "supercalifragilistic expialidocious reminders about groceries always"
        let title = AITriageValidator.validTitle(long)
        XCTAssertNotNil(title)
        XCTAssertLessThanOrEqual(title!.count, AITriageValidator.titleMaxChars)
        XCTAssertFalse(title!.hasSuffix(" "))
    }

    func testEmptyOrDotOnlyTitleRejected() {
        XCTAssertNil(AITriageValidator.validTitle(nil))
        XCTAssertNil(AITriageValidator.validTitle("   "))
        XCTAssertNil(AITriageValidator.validTitle("..."))
    }

    // MARK: - Formatted body

    func testFormattedBodyAcceptedWithinBounds() {
        let raw = "okay so i need to call john tomorrow about the invoice thing"
        let formatted = "Okay, so I need to call John tomorrow about the invoice thing."
        XCTAssertEqual(
            AITriageValidator.validFormattedBody(formatted, rawText: raw, truncated: false),
            formatted
        )
    }

    func testFormattedBodyDiscardedWhenInputTruncated() {
        XCTAssertNil(AITriageValidator.validFormattedBody("Cleaned.", rawText: "Cleaned!", truncated: true))
    }

    func testFormattedBodyDiscardedWhenIdenticalToRaw() {
        let raw = "Already clean text."
        XCTAssertNil(AITriageValidator.validFormattedBody(raw, rawText: raw, truncated: false))
        // Whitespace-trimmed equality also counts as identical.
        XCTAssertNil(AITriageValidator.validFormattedBody("Already clean text.\n", rawText: raw, truncated: false))
    }

    func testFormattedBodyDiscardedWhenTooShortOrTooLong() {
        let raw = String(repeating: "word ", count: 40) // 200 chars
        let tooShort = String(repeating: "w", count: 80)
        let tooLong = String(repeating: "w", count: 320)
        XCTAssertNil(AITriageValidator.validFormattedBody(tooShort, rawText: raw, truncated: false))
        XCTAssertNil(AITriageValidator.validFormattedBody(tooLong, rawText: raw, truncated: false))
    }

    func testFormattedBodyDiscardedWhenEmpty() {
        XCTAssertNil(AITriageValidator.validFormattedBody("   \n", rawText: "raw", truncated: false))
    }

    // MARK: - Handoffs: clause containment

    func testHandoffWithFabricatedClauseDiscardedAndFlagged() {
        let draft = AIEngineDraft(
            classification: "task",
            title: "Call John",
            formattedBody: nil,
            handoffs: [.init(kind: "reminder", title: "Call John", clause: "remind me to buy milk")]
        )
        let output = validate(draft)
        XCTAssertTrue(output.handoffs.isEmpty)
        XCTAssertTrue(output.handoffsInvalidated)
        // The rest of the result still counts.
        XCTAssertEqual(output.classification, .task)
    }

    func testClauseContainmentToleratesCaseAndWhitespaceDrift() {
        let draft = AIEngineDraft(
            handoffs: [.init(kind: "reminder", title: "Call John", clause: "Remind me to  call John")]
        )
        let output = validate(draft, rawText: "um remind me to call john tomorrow")
        XCTAssertEqual(output.handoffs.count, 1)
        XCTAssertFalse(output.handoffsInvalidated)
    }

    func testNoHandoffsInDraftIsNotInvalidated() {
        let output = validate(AIEngineDraft())
        XCTAssertTrue(output.handoffs.isEmpty)
        XCTAssertFalse(output.handoffsInvalidated)
    }

    // MARK: - Handoffs: dates

    func testReminderWithFullDateAndTimeIsTimed() {
        let draft = AIEngineDraft(handoffs: [
            .init(kind: "reminder", title: "Call John", clause: "call John tomorrow at 2",
                  year: 2027, month: 1, day: 15, hour: 14, minute: 0)
        ])
        let output = validate(draft, rawText: "remind me to call John tomorrow at 2")
        guard case .reminder(_, let due)? = output.handoffs.first?.candidate else {
            return XCTFail("expected reminder")
        }
        XCTAssertEqual(due?.hasTime, true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: due!.date)
        XCTAssertEqual(comps.hour, 14)
        XCTAssertEqual(comps.day, 15)
    }

    func testReminderWithDateOnlyIsDateOnly() {
        let draft = AIEngineDraft(handoffs: [
            .init(kind: "reminder", title: "Change filter", clause: "change the filter",
                  year: 2027, month: 1, day: 15)
        ])
        let output = validate(draft, rawText: "remember to change the filter on the fifteenth")
        guard case .reminder(_, let due)? = output.handoffs.first?.candidate else {
            return XCTFail("expected reminder")
        }
        XCTAssertEqual(due?.hasTime, false)
    }

    func testReminderWithPartialDateDegradesToDateless() {
        let draft = AIEngineDraft(handoffs: [
            .init(kind: "reminder", title: "Call mom", clause: "call mom", month: 3, day: 4)
        ])
        let output = validate(draft, rawText: "remind me to call mom")
        guard case .reminder(_, let due)? = output.handoffs.first?.candidate else {
            return XCTFail("expected reminder")
        }
        XCTAssertNil(due)
    }

    func testEventWithoutFullDateTimeDiscarded() {
        let draft = AIEngineDraft(handoffs: [
            .init(kind: "event", title: "Dentist", clause: "dentist appointment tomorrow",
                  year: 2027, month: 1, day: 15) // no time
        ])
        let output = validate(draft, rawText: "dentist appointment tomorrow")
        XCTAssertTrue(output.handoffs.isEmpty)
        XCTAssertTrue(output.handoffsInvalidated)
    }

    func testImpossibleDateDiscardedNotRolled() {
        let draft = AIEngineDraft(handoffs: [
            .init(kind: "event", title: "Meeting", clause: "meeting",
                  year: 2027, month: 2, day: 30, hour: 10, minute: 0)
        ])
        let output = validate(draft, rawText: "meeting on the thirtieth")
        // Feb 30 must not silently become March 2.
        XCTAssertTrue(output.handoffs.isEmpty)
    }

    func testUnknownKindDiscarded() {
        let draft = AIEngineDraft(handoffs: [
            .init(kind: "alarm", title: "Wake up", clause: "wake up")
        ])
        let output = validate(draft, rawText: "wake up early")
        XCTAssertTrue(output.handoffs.isEmpty)
        XCTAssertTrue(output.handoffsInvalidated)
    }

    // MARK: - Handoffs: cap

    func testCapsAtOneReminderAndOneEventFirstWins() {
        let draft = AIEngineDraft(handoffs: [
            .init(kind: "reminder", title: "First reminder", clause: "remind me to do the first thing"),
            .init(kind: "reminder", title: "Second reminder", clause: "remind me to do the second thing"),
            .init(kind: "event", title: "First event", clause: "meeting monday at 2",
                  year: 2027, month: 1, day: 18, hour: 14, minute: 0),
            .init(kind: "event", title: "Second event", clause: "call tuesday at 3",
                  year: 2027, month: 1, day: 19, hour: 15, minute: 0)
        ])
        let raw = "remind me to do the first thing and remind me to do the second thing, meeting monday at 2, call tuesday at 3"
        let output = validate(draft, rawText: raw)
        XCTAssertEqual(output.handoffs.count, 2)
        guard case .reminder(let rTitle, _)? = output.handoffs.first?.candidate,
              case .event(let eTitle, _)? = output.handoffs.last?.candidate else {
            return XCTFail("expected reminder then event")
        }
        XCTAssertEqual(rTitle, "First reminder")
        XCTAssertEqual(eTitle, "First event")
    }

    // MARK: - Routing sanity (CaptureType extension)

    func testNewCaptureTypesRouteToTheirSubfolders() {
        XCTAssertEqual(CaptureType.task.subfolder, "Tasks")
        XCTAssertEqual(CaptureType.idea.subfolder, "Ideas")
        XCTAssertEqual(CaptureType.journal.subfolder, "Journal")
        // Existing routes untouched.
        XCTAssertEqual(CaptureType.voiceNote.subfolder, "Notes")
        XCTAssertEqual(CaptureType.youtubeLink.subfolder, "Links")
        XCTAssertEqual(CaptureType.articleLink.subfolder, "Links")
    }

    func testNewCaptureTypeRawValues() {
        XCTAssertEqual(CaptureType.task.rawValue, "task")
        XCTAssertEqual(CaptureType.idea.rawValue, "idea")
        XCTAssertEqual(CaptureType.journal.rawValue, "journal")
    }
}
