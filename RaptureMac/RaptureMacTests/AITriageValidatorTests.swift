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

    func testTitleRejectsPromptExampleEcho() {
        // A model with nothing to work from echoes the instructions' one
        // concrete example title (2026-07-25 incident). Exactly that string —
        // any casing — must be discarded so the deterministic title applies.
        XCTAssertNil(AITriageValidator.validTitle(AITriagePrompt.exampleTaskTitle))
        XCTAssertNil(AITriageValidator.validTitle("fix the garage door sensor"))
        XCTAssertNil(AITriageValidator.validTitle("  Fix   the garage door sensor "))
        // Nearby-but-different titles still pass.
        XCTAssertEqual(AITriageValidator.validTitle("Fix the garage door"), "Fix the garage door")
        XCTAssertEqual(AITriageValidator.validTitle("Fix the garage door sensor today"), "Fix the garage door sensor today")
    }

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
        // Not "fix the garage door sensor": that exact string is the prompt's
        // example title and is now rejected as an echo (see the test above).
        XCTAssertEqual(AITriageValidator.validTitle("call the plumber about the leak"), "Call the plumber about the leak")
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

    // MARK: - Handoffs: grounds in the note

    /// The capture instant's own date parts: what a model returns when it
    /// copies the "Captured:" stamp and does not read a date from the note.
    private var captureStamp: (year: Int, month: Int, day: Int, hour: Int, minute: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: capturedAt)
        return (c.year!, c.month!, c.day!, c.hour!, c.minute!)
    }

    private func reminderDraft(
        title: String, clause: String,
        year: Int? = nil, month: Int? = nil, day: Int? = nil, hour: Int? = nil, minute: Int? = nil
    ) -> AIEngineDraft {
        AIEngineDraft(handoffs: [
            .init(kind: "reminder", title: title, clause: clause,
                  year: year, month: month, day: day, hour: hour, minute: minute)
        ])
    }

    func testReminderForANoteThatAsksForNothingIsDiscarded() {
        // The 2026-11-16 incident. The note was the one word "Test". The
        // model returned a reminder "Test", quoted "Test" as its clause (so
        // containment passed), and copied the capture stamp as the due time.
        let s = captureStamp
        let draft = reminderDraft(
            title: "Test", clause: "Test",
            year: s.year, month: s.month, day: s.day, hour: s.hour, minute: s.minute
        )
        let output = validate(draft, rawText: "Test")
        XCTAssertTrue(output.handoffs.isEmpty)
        XCTAssertTrue(output.handoffsInvalidated)
        // End to end: the deterministic detector takes over and finds nothing.
        let detected = HandoffManager.candidates(text: "Test", capturedAt: capturedAt, timeZone: zone, ai: output)
        XCTAssertTrue(detected.isEmpty)
    }

    func testReminderForAPlainStatementIsDiscarded() {
        // From the handoff ledger, 2026-09 to 2026-11: statements, video
        // titles and plain to-dos that the model turned into reminders. A
        // to-do with no ask and no date is a task. It files in Tasks/.
        let cases: [(note: String, title: String)] = [
            ("The blue paint is in the garage", "Fix the blue paint in the garage"),
            ("I just saw a good movie about a Mercy Me thing, but it was good", "Movie watching"),
            ("This AI business only needs one client (to make you $1M)", "Investigate AI business"),
            ("I spoke with Deb about the messaging side", "Remind me to speak with Deb"),
            ("https://youtube.com/watch?v=nxGuApt1zhI&is=tqEXbnhX97eY1mbe", "Watch the tutorial"),
            ("Buy milk", "Buy milk"),
        ]
        let s = captureStamp
        for item in cases {
            let dated = reminderDraft(
                title: item.title, clause: item.note,
                year: s.year, month: s.month, day: s.day, hour: s.hour, minute: s.minute
            )
            XCTAssertTrue(validate(dated, rawText: item.note).handoffs.isEmpty, item.note)
            let dateless = reminderDraft(title: item.title, clause: item.note)
            let output = validate(dateless, rawText: item.note)
            XCTAssertTrue(output.handoffs.isEmpty, item.note)
            XCTAssertTrue(output.handoffsInvalidated, item.note)
        }
    }

    func testAnAskToBeRemindedKeepsTheReminder() {
        let notes = [
            "remind me to call mom",
            "Remind me at 5 to call mom",
            "okay so remember to call mom",
            "don't forget the milk",
            "Don’t forget the milk",
            "make sure to call mom",
            "set a reminder to call mom",
            "Add me a reminder for the dentist",
        ]
        for note in notes {
            let output = validate(reminderDraft(title: "Call mom", clause: note), rawText: note)
            XCTAssertEqual(output.handoffs.count, 1, note)
            XCTAssertFalse(output.handoffsInvalidated, note)
        }
    }

    func testADatedErrandWithNoAskKeepsTheReminder() {
        let notes = [
            "send Priya the updated screenshots by Wednesday",
            "pay the electric bill tomorrow",
            "return the drill March 3rd",
            "call John at 2",
            "go to Jason's at 4:30 today to get the prints",
        ]
        for note in notes {
            let output = validate(reminderDraft(title: "Do the errand", clause: note), rawText: note)
            XCTAssertEqual(output.handoffs.count, 1, note)
        }
    }

    func testDueCopiedFromTheCaptureStampIsDropped() {
        // The ask is real, the date is not: the note states no date.
        let s = captureStamp
        let draft = reminderDraft(
            title: "Call mom", clause: "remind me to call mom",
            year: s.year, month: s.month, day: s.day, hour: s.hour, minute: s.minute
        )
        let output = validate(draft, rawText: "remind me to call mom")
        guard case .reminder(let title, let due)? = output.handoffs.first?.candidate else {
            return XCTFail("expected reminder")
        }
        XCTAssertEqual(title, "Call mom")
        XCTAssertNil(due)
    }

    func testDueBeforeTheCaptureIsDropped() {
        // Captured 2027-01-15 03:00 in New York.
        let s = captureStamp
        let earlierThatDay = reminderDraft(
            title: "Call mom", clause: "remind me to call mom",
            year: s.year, month: s.month, day: s.day, hour: 0, minute: 0
        )
        let theDayBefore = reminderDraft(
            title: "Call mom", clause: "remind me to call mom",
            year: s.year, month: s.month, day: s.day - 1
        )
        for draft in [earlierThatDay, theDayBefore] {
            guard case .reminder(_, let due)? = validate(draft, rawText: "remind me to call mom").handoffs.first?.candidate else {
                return XCTFail("expected reminder")
            }
            XCTAssertNil(due)
        }
        // Later the same day is a real due time and stays.
        let laterThatDay = reminderDraft(
            title: "Call mom", clause: "remind me to call mom",
            year: s.year, month: s.month, day: s.day, hour: 17, minute: 0
        )
        guard case .reminder(_, let due)? = validate(laterThatDay, rawText: "remind me to call mom").handoffs.first?.candidate else {
            return XCTFail("expected reminder")
        }
        XCTAssertEqual(due?.hasTime, true)
    }

    func testEventNeedsADayAndATimeInTheNote() {
        // From the ledger: "book the room for the Thursday review" became a
        // calendar event at midnight. The note states a day and no time.
        let cases: [(note: String, day: Int, hour: Int, minute: Int)] = [
            ("book the room for the Thursday review", 21, 0, 0),
            ("dentist tomorrow", 16, 9, 0),
            ("lunch with Sam at 1:10", 15, 13, 10),
            ("Test", 15, 3, 0),
        ]
        for item in cases {
            let draft = AIEngineDraft(handoffs: [
                .init(kind: "event", title: "Event", clause: item.note,
                      year: 2027, month: 1, day: item.day, hour: item.hour, minute: item.minute)
            ])
            let output = validate(draft, rawText: item.note)
            XCTAssertTrue(output.handoffs.isEmpty, item.note)
            XCTAssertTrue(output.handoffsInvalidated, item.note)
        }
    }

    func testEventDayAndTimeMayBeInDifferentSentences() {
        let note = "Call them tomorrow. They open at 8:30."
        let draft = AIEngineDraft(handoffs: [
            .init(kind: "event", title: "Call the dentist", clause: "Call them tomorrow",
                  year: 2027, month: 1, day: 16, hour: 8, minute: 30)
        ])
        let output = validate(draft, rawText: note)
        guard case .event(let title, _)? = output.handoffs.first?.candidate else {
            return XCTFail("expected event")
        }
        XCTAssertEqual(title, "Call the dentist")
    }

    func testHandoffTitledWithThePromptExampleIsDiscarded() {
        // From the ledger: a reminder "Fix the garage door sensor" for a note
        // that was a link. The model echoed the prompt's example title.
        let note = "remind me to look at this tomorrow"
        let draft = reminderDraft(title: AITriagePrompt.exampleTaskTitle.lowercased(), clause: note)
        let output = validate(draft, rawText: note)
        XCTAssertTrue(output.handoffs.isEmpty)
        XCTAssertTrue(output.handoffsInvalidated)
    }

    func testNoteGrounds() {
        let cases: [(note: String, asks: Bool, day: Bool, time: Bool)] = [
            ("Test", false, false, false),
            ("The blue paint is in the garage", false, false, false),
            ("I reminded him about the invoice", false, false, false),
            ("https://youtube.com/watch?v=nxGuApt1zhI&is=tqEXbnhX97eY1mbe", false, false, false),
            ("remind me to call mom", true, false, false),
            ("Don’t forget the milk", true, false, false),
            ("call John tomorrow", false, true, false),
            ("call John at 2", false, false, true),
            ("remind me to call John tomorrow at 2", true, true, true),
            ("Call them tomorrow. They open at 8:30.", false, true, true),
        ]
        for item in cases {
            let grounds = AITriageValidator.noteGrounds(in: item.note, capturedAt: capturedAt, timeZone: zone)
            XCTAssertEqual(grounds.asksForReminder, item.asks, item.note)
            XCTAssertEqual(grounds.statesDay, item.day, item.note)
            XCTAssertEqual(grounds.statesTime, item.time, item.note)
            XCTAssertEqual(grounds.allowsReminder, item.asks || item.day || item.time, item.note)
            XCTAssertEqual(grounds.allowsEvent, item.day && item.time, item.note)
        }
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
