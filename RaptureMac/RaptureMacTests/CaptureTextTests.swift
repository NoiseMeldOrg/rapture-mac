import XCTest
@testable import Rapture

/// The shared "is there anything dictated here?" definition. Locks the
/// 2026-07-25 incident's root: U+FFFC (what iMessage puts in the text of an
/// attachment-only message) is category So, not whitespace, so plain trimming
/// called it content.
final class CaptureTextTests: XCTestCase {

    // MARK: - strippingInvisibles

    func testStripsObjectReplacementCharacter() {
        XCTAssertEqual(CaptureText.strippingInvisibles("\u{FFFC}"), "")
        XCTAssertEqual(CaptureText.strippingInvisibles("check this \u{FFFC} out"), "check this  out")
    }

    func testStripsFormatCharacters() {
        // ZWJ, zero-width space, BOM, left-to-right mark
        XCTAssertEqual(CaptureText.strippingInvisibles("\u{200D}\u{200B}\u{FEFF}\u{200E}"), "")
    }

    func testStripsVariationSelectors() {
        XCTAssertEqual(CaptureText.strippingInvisibles("\u{2764}\u{FE0F}"), "\u{2764}")
    }

    func testVisibleTextUntouched() {
        XCTAssertEqual(CaptureText.strippingInvisibles("rent is due on the 5th"), "rent is due on the 5th")
    }

    // MARK: - isContentFree

    func testEmptyAndWhitespaceAreContentFree() {
        XCTAssertTrue(CaptureText.isContentFree(""))
        XCTAssertTrue(CaptureText.isContentFree("   \n\t"))
    }

    func testAttachmentPlaceholderOnlyIsContentFree() {
        XCTAssertTrue(CaptureText.isContentFree("\u{FFFC}"))
        XCTAssertTrue(CaptureText.isContentFree("\u{FFFC} \u{FFFC}\n"))
    }

    func testInvisibleSoupIsContentFree() {
        XCTAssertTrue(CaptureText.isContentFree("\u{200B}\u{FEFF} \u{200D}"))
    }

    func testRealWordsAreNotContentFree() {
        XCTAssertFalse(CaptureText.isContentFree("rent is due on the 5th"))
        XCTAssertFalse(CaptureText.isContentFree("check this \u{FFFC}"))
    }

    func testBareEmojiIsNotContentFree() {
        // A dictated "❤️" is content; only the variation selector strips.
        XCTAssertFalse(CaptureText.isContentFree("\u{2764}\u{FE0F}"))
    }
}
