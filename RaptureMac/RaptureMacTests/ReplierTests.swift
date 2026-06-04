import XCTest
@testable import Rapture

final class ReplierTests: XCTestCase {

    private func successOutcome(filename: String = "2026-05-19T04-12-08Z.txt") -> WriteResult.Outcome {
        let url = URL(fileURLWithPath: "/tmp/Rapture Notes/").appendingPathComponent(filename)
        return .success(url)
    }

    // MARK: - composeReplyText

    func testReplyAllSuccess() {
        let text = Replier.composeReplyText(replyMode: .all, outcome: successOutcome())
        XCTAssertEqual(text, "✅ Saved")
    }

    func testReplyAllSuccessOmitsFilename() {
        // The reply intentionally drops the filename — user can't act on a path
        // from their phone, and the short form is easier to glance at.
        let text = Replier.composeReplyText(
            replyMode: .all,
            outcome: successOutcome(filename: "2026-06-04T08-22-17Z-99.txt")
        )
        XCTAssertEqual(text, "✅ Saved")
    }

    func testReplyAllFailure() {
        let text = Replier.composeReplyText(replyMode: .all, outcome: .failure(reason: "Folder not writable"))
        XCTAssertEqual(text, "✗ Folder not writable")
    }

    func testReplyErrorsOnlySuccessSuppressed() {
        let text = Replier.composeReplyText(replyMode: .errorsOnly, outcome: successOutcome())
        XCTAssertNil(text)
    }

    func testReplyErrorsOnlyFailureFires() {
        let text = Replier.composeReplyText(replyMode: .errorsOnly, outcome: .failure(reason: "Disk full"))
        XCTAssertEqual(text, "✗ Disk full")
    }

    func testReplyOffNeverFires() {
        XCTAssertNil(Replier.composeReplyText(replyMode: .off, outcome: successOutcome()))
        XCTAssertNil(Replier.composeReplyText(replyMode: .off, outcome: .failure(reason: "anything")))
    }

    // MARK: - composeCatchupText

    func testCatchupTextSuccessOnly() {
        let text = Replier.composeCatchupText(successCount: 5, failureCount: 0)
        XCTAssertEqual(text, "📥 Caught up: 5 notes")
    }

    func testCatchupTextWithFailures() {
        let text = Replier.composeCatchupText(successCount: 4, failureCount: 1)
        XCTAssertEqual(text, "📥 Caught up: 4 notes (1 failed)")
    }

    func testCatchupTextZeroSuccessWithFailures() {
        let text = Replier.composeCatchupText(successCount: 0, failureCount: 3)
        XCTAssertEqual(text, "📥 Caught up: 0 notes (3 failed)")
    }

    // MARK: - catchupDestination

    func testCatchupDestinationChatWhenSelfChatKnown() {
        let dest = Replier.catchupDestination(replyMode: .all, selfChatGuid: "iMessage;-;chat-self")
        XCTAssertEqual(dest, .chat("iMessage;-;chat-self"))
    }

    func testCatchupDestinationNotificationWhenSelfChatMissing() {
        let dest = Replier.catchupDestination(replyMode: .all, selfChatGuid: nil)
        XCTAssertEqual(dest, .notification)
    }

    func testCatchupDestinationNotificationWhenReplyModeOff() {
        let dest = Replier.catchupDestination(replyMode: .off, selfChatGuid: "iMessage;-;chat-self")
        XCTAssertEqual(dest, .notification)
    }

    func testCatchupDestinationNotificationWhenErrorsOnlyAndSelfChatKnown() {
        // errorsOnly still allows the summary to land in chat (a catch-up summary that
        // succeeds is informational rather than an error; the explicit toggle to suppress
        // it is .off, not .errorsOnly).
        let dest = Replier.catchupDestination(replyMode: .errorsOnly, selfChatGuid: "iMessage;-;chat-self")
        XCTAssertEqual(dest, .chat("iMessage;-;chat-self"))
    }
}
