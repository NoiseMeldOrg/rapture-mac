import XCTest
@testable import Rapture

/// Behavior table for deterministic title derivation. Expected values are literals
/// from the PRD and the user's proven routing rulebook — not recomputed.
final class TitleDeriverTests: XCTestCase {

    // MARK: - Voice notes: first words, cleaned

    func testShortDictationUsedAsIs() {
        XCTAssertEqual(TitleDeriver.voiceNoteTitle(from: "rent is due on the 5th"), "Rent is due on the 5th")
    }

    func testLongDictationTruncatesToEightWords() {
        let text = "I just wanna say that I need to actually get Tyler's money for his graduation gift"
        XCTAssertEqual(TitleDeriver.voiceNoteTitle(from: text), "I just wanna say that I need to")
    }

    func testSixtyCharCapAppliesBeforeEightWords() {
        let text = "Extraordinarily complicated multisyllabic terminology desperately needs abbreviation somewhere"
        let title = TitleDeriver.voiceNoteTitle(from: text)
        XCTAssertLessThanOrEqual(title.count, 60)
        XCTAssertFalse(title.hasSuffix(" "), "no trailing whitespace after the cap")
    }

    func testNewlinesAndExtraWhitespaceCollapse() {
        XCTAssertEqual(TitleDeriver.voiceNoteTitle(from: "buy   bacon\nand ground beef"), "Buy bacon and ground beef")
    }

    func testFilesystemHostileCharactersSanitized() {
        XCTAssertEqual(TitleDeriver.voiceNoteTitle(from: "either/or: a plan"), "Either or a plan")
    }

    func testLeadingDotsStripped() {
        XCTAssertFalse(TitleDeriver.voiceNoteTitle(from: "...quiet thought").hasPrefix("."))
    }

    func testEmptyTextFallsBackToNote() {
        XCTAssertEqual(TitleDeriver.voiceNoteTitle(from: ""), "Note")
        XCTAssertEqual(TitleDeriver.voiceNoteTitle(from: "  \n "), "Note")
    }

    func testFirstLetterCapitalizedOnly() {
        XCTAssertEqual(TitleDeriver.voiceNoteTitle(from: "buy bacon NOW please"), "Buy bacon NOW please")
    }

    // MARK: - Link titles

    func testYouTubeWatchTitleUsesVideoID() {
        XCTAssertEqual(
            TitleDeriver.linkTitle(for: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", type: .youtubeLink),
            "YouTube dQw4w9WgXcQ"
        )
    }

    func testYoutuBeTitleUsesVideoID() {
        XCTAssertEqual(
            TitleDeriver.linkTitle(for: "https://youtu.be/dQw4w9WgXcQ", type: .youtubeLink),
            "YouTube dQw4w9WgXcQ"
        )
    }

    func testYouTubeShortsAndLiveUseSlug() {
        XCTAssertEqual(
            TitleDeriver.linkTitle(for: "https://www.youtube.com/shorts/abc123", type: .youtubeLink),
            "YouTube abc123"
        )
        XCTAssertEqual(
            TitleDeriver.linkTitle(for: "https://www.youtube.com/live/xyz789", type: .youtubeLink),
            "YouTube xyz789"
        )
    }

    func testYouTubeWithoutRecognizableIDFallsBackToPlainYouTube() {
        XCTAssertEqual(
            TitleDeriver.linkTitle(for: "https://www.youtube.com/@somechannel", type: .youtubeLink),
            "YouTube"
        )
    }

    func testArticleTitleUsesHostWithoutWww() {
        XCTAssertEqual(
            TitleDeriver.linkTitle(for: "https://www.example.com/deep/path?q=1", type: .articleLink),
            "example.com"
        )
    }

    func testUnparseableLinkFallsBackToLink() {
        XCTAssertEqual(TitleDeriver.linkTitle(for: "", type: .articleLink), "Link")
    }

    // MARK: - Relay basenames (iOS-derived titles)

    func testRelayBaseNameYieldsItsTitlePart() {
        XCTAssertEqual(
            TitleDeriver.relayTitle(fromBaseName: "2026-07-06T15-14-42Z Grocery Ideas"),
            "Grocery Ideas"
        )
    }

    func testPureTimestampBaseNameHasNoRelayTitle() {
        XCTAssertNil(TitleDeriver.relayTitle(fromBaseName: "2026-07-06T15-14-42Z"))
        XCTAssertNil(TitleDeriver.relayTitle(fromBaseName: "2026-07-06T15-14-42Z-1"))
    }

    func testNonContractBaseNameHasNoRelayTitle() {
        XCTAssertNil(TitleDeriver.relayTitle(fromBaseName: "random note"))
    }
}
