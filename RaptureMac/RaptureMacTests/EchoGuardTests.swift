import XCTest
@testable import RaptureMac

final class EchoGuardTests: XCTestCase {

    // MARK: - normalize()

    func testNormalizeLowercasesAndTrims() {
        XCTAssertEqual(EchoGuard.normalize("  HELLO World  "), "hello world")
    }

    func testNormalizeStripsSentByClaudeSuffix() {
        XCTAssertEqual(EchoGuard.normalize("hello Sent by Claude"), "hello")
        XCTAssertEqual(EchoGuard.normalize("hello sent by claude"), "hello")
        XCTAssertEqual(EchoGuard.normalize("hello SENT BY CLAUDE"), "hello")
    }

    func testNormalizeDoesNotStripMidStringSentByClaude() {
        // The suffix marker is anchored at end; mid-string occurrences must pass through.
        XCTAssertEqual(EchoGuard.normalize("Sent by Claude is the prefix here"), "sent by claude is the prefix here")
    }

    func testNormalizeStripsZWJAndVariationSelectors() {
        let input = "5\u{FE0F}\u{20E3} family\u{200D}thing"
        let output = EchoGuard.normalize(input)
        XCTAssertFalse(output.contains("\u{200D}"))
        XCTAssertFalse(output.contains("\u{FE0F}"))
    }

    func testNormalizeReplacesSmartQuotes() {
        XCTAssertEqual(EchoGuard.normalize("\u{201C}hello\u{201D} \u{2018}world\u{2019}"), "\"hello\" 'world'")
    }

    func testNormalizeCollapsesWhitespace() {
        XCTAssertEqual(EchoGuard.normalize("hello   \t\nworld"), "hello world")
    }

    func testNormalizeCapsAt120Chars() {
        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(EchoGuard.normalize(long).count, 120)
    }

    func testNormalizeAppliesAllRulesInOrder() {
        let input = "  \u{201C}Hello\u{201D}  WORLD  \u{200D}  Sent by Claude"
        XCTAssertEqual(EchoGuard.normalize(input), "\"hello\" world")
    }

    // MARK: - appendEntry / consumeMatch (pure helpers)

    func testAppendThenConsumeMatches() {
        let now = Date()
        let entries = EchoGuard.appendEntry(into: [], chatGuid: "chat-1", text: "✓ Saved: a.txt", now: now)
        XCTAssertEqual(entries.count, 1)

        let result = EchoGuard.consumeMatch(from: entries, chatGuid: "chat-1", text: "✓ saved: a.txt  ", now: now.addingTimeInterval(1))
        XCTAssertTrue(result.matched)
        XCTAssertTrue(result.remaining.isEmpty)
    }

    func testConsumeIsOneShot() {
        let now = Date()
        let entries = EchoGuard.appendEntry(into: [], chatGuid: "chat-1", text: "hi", now: now)
        let first = EchoGuard.consumeMatch(from: entries, chatGuid: "chat-1", text: "hi", now: now)
        let second = EchoGuard.consumeMatch(from: first.remaining, chatGuid: "chat-1", text: "hi", now: now)
        XCTAssertTrue(first.matched)
        XCTAssertFalse(second.matched)
    }

    func testConsumeRequiresMatchingChatGuid() {
        let now = Date()
        let entries = EchoGuard.appendEntry(into: [], chatGuid: "chat-1", text: "hi", now: now)
        let result = EchoGuard.consumeMatch(from: entries, chatGuid: "chat-2", text: "hi", now: now)
        XCTAssertFalse(result.matched)
        XCTAssertEqual(result.remaining.count, 1)
    }

    func testConsumeAfterTTLExpiry() {
        let now = Date()
        let entries = EchoGuard.appendEntry(into: [], chatGuid: "chat-1", text: "hi", now: now)
        let later = now.addingTimeInterval(EchoGuard.ttl + 1)
        let result = EchoGuard.consumeMatch(from: entries, chatGuid: "chat-1", text: "hi", now: later)
        XCTAssertFalse(result.matched)
        XCTAssertTrue(result.remaining.isEmpty, "Expired entries should be pruned")
    }

    func testAppendPrunesExpiredEntries() {
        let past = Date(timeIntervalSinceNow: -100)
        let stale = EchoEntry(chatGuid: "chat-1", normalizedText: "old", expiresAt: past)
        let now = Date()
        let entries = EchoGuard.appendEntry(into: [stale], chatGuid: "chat-2", text: "new", now: now)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.chatGuid, "chat-2")
    }
}
