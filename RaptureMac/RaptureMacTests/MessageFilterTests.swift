import XCTest
@testable import Rapture

final class MessageFilterTests: XCTestCase {

    // MARK: - looksLikeAppConfirmation pattern matcher

    func testMatchesShortSavedConfirmation() {
        // Current short form (no filename) — what the app emits today.
        XCTAssertTrue(MessageFilter.looksLikeAppConfirmation("✅ Saved"))
        XCTAssertTrue(MessageFilter.looksLikeAppConfirmation("  ✅ Saved  "))
    }

    func testMatchesLegacySavedConfirmationNoSuffix() {
        // Pre-upgrade format. iCloud can replay these days later; keep matching.
        XCTAssertTrue(MessageFilter.looksLikeAppConfirmation("✓ Saved: 2026-05-20T19-16-54Z.txt"))
    }

    func testMatchesLegacySavedConfirmationWithCollisionSuffix() {
        XCTAssertTrue(MessageFilter.looksLikeAppConfirmation("✓ Saved: 2026-05-20T19-16-54Z-3.txt"))
        XCTAssertTrue(MessageFilter.looksLikeAppConfirmation("✓ Saved: 2026-05-20T19-16-54Z-82.txt"))
    }

    func testMatchesCatchupSummary() {
        // Current short form.
        XCTAssertTrue(MessageFilter.looksLikeAppConfirmation("📥 Caught up: 5 notes"))
        XCTAssertTrue(MessageFilter.looksLikeAppConfirmation("📥 Caught up: 12 notes (3 failed)"))
        // Legacy long form — iCloud replays of pre-upgrade summaries.
        XCTAssertTrue(MessageFilter.looksLikeAppConfirmation("📥 Caught up: 5 notes captured"))
        XCTAssertTrue(MessageFilter.looksLikeAppConfirmation("📥 Caught up: 12 notes captured (3 failed)"))
    }

    func testMatchesFailureReply() {
        XCTAssertTrue(MessageFilter.looksLikeAppConfirmation("✗ Folder not writable"))
        XCTAssertTrue(MessageFilter.looksLikeAppConfirmation("✗ Reply failed: SQLite error 14"))
    }

    func testIgnoresLeadingWhitespace() {
        XCTAssertTrue(MessageFilter.looksLikeAppConfirmation("  ✓ Saved: 2026-05-20T19-16-54Z.txt  "))
    }

    // MARK: - negatives (should NOT be flagged as app confirmation)

    func testRejectsArbitraryUserText() {
        XCTAssertFalse(MessageFilter.looksLikeAppConfirmation("Rent is due on the 5th"))
        XCTAssertFalse(MessageFilter.looksLikeAppConfirmation("Reminder to call Bob"))
        XCTAssertFalse(MessageFilter.looksLikeAppConfirmation("https://example.com/something"))
    }

    func testRejectsSavedPrefixWithoutValidFilename() {
        // The right prefix but the body doesn't match the timestamp-filename pattern
        XCTAssertFalse(MessageFilter.looksLikeAppConfirmation("✓ Saved: notes.txt"))
        XCTAssertFalse(MessageFilter.looksLikeAppConfirmation("✓ Saved: my custom name.txt"))
        XCTAssertFalse(MessageFilter.looksLikeAppConfirmation("✓ Saved: 2026-05-20.txt"))
        XCTAssertFalse(MessageFilter.looksLikeAppConfirmation("✓ Saved: 2026-05-20T19-16-54Z"))  // missing .txt
    }

    func testRejectsSavedPrefixWithMalformedSuffix() {
        XCTAssertFalse(MessageFilter.looksLikeAppConfirmation("✓ Saved: 2026-05-20T19-16-54Z-a.txt"))  // letter, not digit
        XCTAssertFalse(MessageFilter.looksLikeAppConfirmation("✓ Saved: 2026-05-20T19-16-54Z-.txt"))   // empty N
    }

    func testRejectsCheckmarkAlone() {
        XCTAssertFalse(MessageFilter.looksLikeAppConfirmation("✓"))
        XCTAssertFalse(MessageFilter.looksLikeAppConfirmation("✓ something else"))
        XCTAssertFalse(MessageFilter.looksLikeAppConfirmation("✅"))
        XCTAssertFalse(MessageFilter.looksLikeAppConfirmation("✅ Saved!"))  // exact match only
        XCTAssertFalse(MessageFilter.looksLikeAppConfirmation("✅ saved"))   // case-sensitive
    }

    // MARK: - End-to-end: MessageFilter.decide drops these on self-chat

    private func appConfirmationEvent(text: String, handle: String = "+15555550199") -> MessageEvent {
        MessageEvent(
            rowid: 1,
            guid: "test-guid",
            text: text,
            attributedBody: nil,
            dateAppleNs: 0,
            isFromMe: false,
            cacheHasAttachments: false,
            service: "iMessage",
            handleId: handle,
            chatGuid: "iMessage;-;chat-guid",
            chatStyle: 45,
            attachments: []
        )
    }

    func testFilterDropsAppConfirmationFromSelfChat() {
        let event = appConfirmationEvent(text: "✓ Saved: 2026-05-20T19-16-54Z.txt")
        let selfHandles: Set<String> = ["+15555550199"]
        let settings = Settings()

        let decision = MessageFilter.decide(event: event, selfHandles: selfHandles, settings: settings)

        switch decision {
        case .drop(let reason):
            XCTAssertEqual(reason, .appConfirmation)
        case .capture:
            XCTFail("Expected drop(.appConfirmation), got capture")
        }
    }

    func testFilterDropsShortFormSavedFromSelfChat() {
        let event = appConfirmationEvent(text: "✅ Saved")
        let selfHandles: Set<String> = ["+15555550199"]
        let settings = Settings()

        let decision = MessageFilter.decide(event: event, selfHandles: selfHandles, settings: settings)

        if case .drop(let reason) = decision {
            XCTAssertEqual(reason, .appConfirmation)
        } else {
            XCTFail("Expected drop(.appConfirmation)")
        }
    }

    func testFilterDropsCatchupSummaryFromSelfChat() {
        let event = appConfirmationEvent(text: "📥 Caught up: 5 notes captured")
        let selfHandles: Set<String> = ["+15555550199"]
        let settings = Settings()

        let decision = MessageFilter.decide(event: event, selfHandles: selfHandles, settings: settings)

        if case .drop(let reason) = decision {
            XCTAssertEqual(reason, .appConfirmation)
        } else {
            XCTFail("Expected drop(.appConfirmation)")
        }
    }

    func testFilterCapturesNormalSelfChatMessage() {
        let event = appConfirmationEvent(text: "Rent is due on the 5th")
        let selfHandles: Set<String> = ["+15555550199"]
        let settings = Settings()

        let decision = MessageFilter.decide(event: event, selfHandles: selfHandles, settings: settings)

        if case .capture(let captured) = decision {
            XCTAssertEqual(captured.decodedText, "Rent is due on the 5th")
        } else {
            XCTFail("Expected capture, got drop")
        }
    }

    func testFilterDoesNotDropAppConfirmationFromAllowlistedNonSelfHandle() {
        // The pattern is only a self-handle drop. An allowlisted non-self contact
        // that somehow sent us text matching ✓ Saved: <…>.txt is captured normally.
        var settings = Settings()
        settings.allowedHandles = ["+15555550123"]
        let event = appConfirmationEvent(text: "✓ Saved: 2026-05-20T19-16-54Z.txt", handle: "+15555550123")
        let selfHandles: Set<String> = ["+15555550199"]

        let decision = MessageFilter.decide(event: event, selfHandles: selfHandles, settings: settings)

        if case .capture = decision {
            // expected
        } else {
            XCTFail("Allowlisted (non-self) sender's text should be captured even if it matches the confirmation pattern")
        }
    }
}
