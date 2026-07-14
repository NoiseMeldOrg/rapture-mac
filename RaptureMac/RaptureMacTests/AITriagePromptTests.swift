import XCTest
@testable import Rapture

final class AITriagePromptTests: XCTestCase {

    func testShortTextNotClipped() {
        let (text, truncated) = AITriagePrompt.clip("hello world")
        XCTAssertEqual(text, "hello world")
        XCTAssertFalse(truncated)
    }

    func testExactLimitNotClipped() {
        let input = String(repeating: "a", count: AITriagePrompt.maxInputChars)
        let (text, truncated) = AITriagePrompt.clip(input)
        XCTAssertEqual(text.count, AITriagePrompt.maxInputChars)
        XCTAssertFalse(truncated)
    }

    func testOverLimitClippedAndFlagged() {
        let input = String(repeating: "a", count: AITriagePrompt.maxInputChars + 1)
        let (text, truncated) = AITriagePrompt.clip(input)
        XCTAssertEqual(text.count, AITriagePrompt.maxInputChars)
        XCTAssertTrue(truncated)
    }

    func testClipIsCharacterBoundarySafe() {
        // Multi-scalar emoji at the cut point must not shatter into invalid UTF-8.
        let prefix = String(repeating: "a", count: AITriagePrompt.maxInputChars - 1)
        let input = prefix + "👨‍👩‍👧‍👦xyz"
        let (text, truncated) = AITriagePrompt.clip(input)
        XCTAssertTrue(truncated)
        // String.prefix counts Characters, so the emoji survives whole or not at all.
        XCTAssertEqual(text.count, AITriagePrompt.maxInputChars)
        XCTAssertNotNil(text.data(using: .utf8))
    }

    func testUserMessageCarriesWeekdayInstantZoneAndText() {
        let zone = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        // 2026-07-13 is a Monday.
        let capturedAt = calendar.date(from: DateComponents(year: 2026, month: 7, day: 13, hour: 19, minute: 5))!
        let message = AITriagePrompt.userMessage(text: "remind me tomorrow", capturedAt: capturedAt, timeZone: zone)
        XCTAssertTrue(message.contains("Monday 2026-07-13 19:05"))
        XCTAssertTrue(message.contains("America/New_York"))
        XCTAssertTrue(message.contains("remind me tomorrow"))
    }

    func testInstructionsNameTheContract() {
        // Guard the load-bearing vocabulary both engines share.
        for token in ["task", "idea", "journal", "null", "formattedBody", "handoffs", "verbatim clause"] {
            XCTAssertTrue(AITriagePrompt.instructions.contains(token), "instructions lost token: \(token)")
        }
    }
}
