import XCTest
@testable import Rapture

final class AllowlistInputTests: XCTestCase {

    func testTrimsWhitespace() {
        XCTAssertEqual(AllowlistInput.normalize("  hi@example.com  "), "hi@example.com")
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(AllowlistInput.normalize(""))
        XCTAssertNil(AllowlistInput.normalize("   "))
        XCTAssertNil(AllowlistInput.normalize("\n\t"))
    }

    func testStripsApplePrefix() {
        XCTAssertEqual(AllowlistInput.normalize("E:hi@example.com"), "hi@example.com")
        XCTAssertEqual(AllowlistInput.normalize("p:+15555550123"), "+15555550123")
    }

    func testPrefixOnlyEntryReturnsNil() {
        XCTAssertNil(AllowlistInput.normalize("E:"))
    }

    func testDoesNotStripWhenNotALetterPrefix() {
        XCTAssertEqual(AllowlistInput.normalize("1:foo"), "1:foo")
        XCTAssertEqual(AllowlistInput.normalize(":foo"), ":foo")
    }

    func testAppendingAddsNewEntry() {
        let updated = AllowlistInput.appending("hi@example.com", to: [])
        XCTAssertEqual(updated, ["hi@example.com"])
    }

    func testAppendingDedupesCaseInsensitive() {
        let updated = AllowlistInput.appending("Hi@Example.com", to: ["hi@example.com"])
        XCTAssertEqual(updated, ["hi@example.com"])
    }

    func testAppendingRefusesEmpty() {
        let original = ["+15555550123"]
        XCTAssertEqual(AllowlistInput.appending("", to: original), original)
        XCTAssertEqual(AllowlistInput.appending("  ", to: original), original)
    }

    func testAppendingAllowsDistinctEntries() {
        let updated = AllowlistInput.appending("+15555550124", to: ["+15555550123"])
        XCTAssertEqual(updated, ["+15555550123", "+15555550124"])
    }

    func testAppendingNormalizesBeforeChecking() {
        // Apple-prefix on both sides should be deduped.
        let updated = AllowlistInput.appending("E:friend@example.com", to: ["friend@example.com"])
        XCTAssertEqual(updated, ["friend@example.com"])
    }
}
