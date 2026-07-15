import XCTest
@testable import Rapture

/// The anti-drift guard between `Replier` (what we send) and
/// `MessageFilter.looksLikeAppConfirmation` (what we refuse to re-capture).
///
/// These tests deliberately derive their inputs from `Replier`'s own composers
/// instead of hardcoding strings. Hardcoded expectations are what let the
/// 2026-07-14 echo incident happen: `looksLikeAppConfirmation` tested
/// `== "✅ Saved"` and had a passing test for exactly that string, while M3 had
/// started appending ` · Reminder created` and M2 had added the queued reply.
/// Both new shapes sailed through the filter. One came back via iCloud with
/// `is_from_me=0`, filed as a note, and AI triage classified it as a task and
/// created a junk "Reminder created" reminder.
///
/// If someone adds a reply shape to `Replier` and forgets the filter, a test
/// here fails. That is the entire point — do not replace these loops with
/// literal strings.
final class ReplierEchoFilterTests: XCTestCase {

    /// Every `HandoffOutcome` the manager can report.
    private static let allHandoffOutcomes: [HandoffOutcome] = [
        HandoffOutcome(reminderCreated: false, eventCreated: false),
        HandoffOutcome(reminderCreated: true, eventCreated: false),
        HandoffOutcome(reminderCreated: false, eventCreated: true),
        HandoffOutcome(reminderCreated: true, eventCreated: true),
    ]

    // MARK: - The regression that started it all

    func testSavedWithReminderSuffixIsFiltered() {
        // The exact text that filed as Tasks/2026-07-14 Saved.md on 2026-07-14
        // and then produced a junk reminder titled "Reminder created".
        XCTAssertTrue(MessageFilter.looksLikeAppConfirmation("✅ Saved · Reminder created"))
    }

    // MARK: - Derived coverage: every success reply, every handoff combination

    func testEverySuccessReplyIsFiltered() {
        for handoff in Self.allHandoffOutcomes {
            guard let reply = Replier.composeReplyText(
                replyMode: .all,
                outcome: .success(URL(fileURLWithPath: "/tmp/note.md")),
                handoff: handoff
            ) else {
                XCTFail("Replier emitted no success reply for \(handoff); this test needs updating")
                continue
            }
            XCTAssertTrue(
                MessageFilter.looksLikeAppConfirmation(reply),
                "Replier sends \"\(reply)\" but MessageFilter would re-capture it as a note"
            )
        }
    }

    func testSpooledReplyIsFiltered() {
        guard let reply = Replier.composeSpooledReplyText(replyMode: .all) else {
            return XCTFail("Replier emitted no spooled reply; this test needs updating")
        }
        XCTAssertTrue(
            MessageFilter.looksLikeAppConfirmation(reply),
            "Replier sends \"\(reply)\" but MessageFilter would re-capture it as a note"
        )
    }

    func testFailureReplyIsFiltered() {
        for reason in ["Folder not writable", "Reply failed: SQLite error 14", "Disk full"] {
            guard let reply = Replier.composeReplyText(
                replyMode: .all,
                outcome: .failure(reason: reason)
            ) else {
                return XCTFail("Replier emitted no failure reply; this test needs updating")
            }
            XCTAssertTrue(
                MessageFilter.looksLikeAppConfirmation(reply),
                "Replier sends \"\(reply)\" but MessageFilter would re-capture it as a note"
            )
        }
    }

    func testCatchupSummariesAreFiltered() {
        for (success, failure) in [(1, 0), (5, 0), (12, 3), (0, 2)] {
            let reply = Replier.composeCatchupText(successCount: success, failureCount: failure)
            XCTAssertTrue(
                MessageFilter.looksLikeAppConfirmation(reply),
                "Replier sends \"\(reply)\" but MessageFilter would re-capture it as a note"
            )
        }
    }

    /// iCloud can replay a reply days later, so trimming must not defeat the match.
    func testRepliesAreFilteredWithSurroundingWhitespace() {
        for handoff in Self.allHandoffOutcomes {
            guard let reply = Replier.composeReplyText(
                replyMode: .all,
                outcome: .success(URL(fileURLWithPath: "/tmp/note.md")),
                handoff: handoff
            ) else { continue }
            XCTAssertTrue(MessageFilter.looksLikeAppConfirmation("  \(reply)  "))
            XCTAssertTrue(MessageFilter.looksLikeAppConfirmation("\n\(reply)\n"))
        }
    }

    // MARK: - The other half: real dictation must still capture

    /// The filter is defense in depth, not a licence to drop user notes.
    /// "Never drop a capture" (mission.md) outranks echo suppression, so these
    /// must all survive — including notes that merely mention the word "saved".
    func testNaturalDictationIsNotFiltered() {
        let realNotes = [
            "Saved the file to the shared drive",
            "Remind me to check whether the invoice saved correctly",
            "✅ is the emoji I want on the dashboard",
            "Queued the deploy for tomorrow morning",
            "Caught up with Sam about the roadmap",
            "Saved · a note about the interpunct character",
            "The build failed with error 14",
        ]
        for note in realNotes {
            XCTAssertFalse(
                MessageFilter.looksLikeAppConfirmation(note),
                "MessageFilter would drop the real dictation \"\(note)\""
            )
        }
    }
}
