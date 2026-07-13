import XCTest
@testable import Rapture

/// Behavior table for deterministic capture classification, per the locked PRD:
/// a link capture requires an explicit scheme (or www.) in the dictated text, is
/// URL-dominant (little commentary), and splits YouTube vs article by host.
final class TriageClassifierTests: XCTestCase {

    // MARK: - YouTube forms

    func testBareYouTubeWatchURL() {
        let c = TriageClassifier.classify("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertEqual(c.type, .youtubeLink)
        XCTAssertEqual(c.rawMedia, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    func testYoutuBeShortURL() {
        let c = TriageClassifier.classify("https://youtu.be/dQw4w9WgXcQ")
        XCTAssertEqual(c.type, .youtubeLink)
    }

    func testMobileYouTubeShorts() {
        let c = TriageClassifier.classify("https://m.youtube.com/shorts/abc123")
        XCTAssertEqual(c.type, .youtubeLink)
    }

    func testYouTubeLiveForm() {
        let c = TriageClassifier.classify("https://www.youtube.com/live/abc123")
        XCTAssertEqual(c.type, .youtubeLink)
    }

    func testYouTubeWithShortCommentaryStaysLink() {
        let c = TriageClassifier.classify("check this out https://youtube.com/watch?v=xyz9")
        XCTAssertEqual(c.type, .youtubeLink)
        XCTAssertEqual(c.rawMedia, "https://youtube.com/watch?v=xyz9")
    }

    // MARK: - Articles

    func testBareArticleURL() {
        let c = TriageClassifier.classify("https://example.com/article")
        XCTAssertEqual(c.type, .articleLink)
        XCTAssertEqual(c.rawMedia, "https://example.com/article")
    }

    func testWwwWithoutSchemeQualifies() {
        let c = TriageClassifier.classify("www.example.com/post")
        XCTAssertEqual(c.type, .articleLink)
        XCTAssertNotNil(c.rawMedia)
    }

    func testUppercaseSchemeQualifies() {
        let c = TriageClassifier.classify("HTTPS://EXAMPLE.COM/x")
        XCTAssertEqual(c.type, .articleLink)
    }

    func testTwoURLsWithLittleElseUsesFirst() {
        let c = TriageClassifier.classify("compare https://example.com/a and https://example.com/b")
        XCTAssertEqual(c.type, .articleLink)
        XCTAssertEqual(c.rawMedia, "https://example.com/a")
    }

    // MARK: - Voice notes

    func testPlainDictationIsVoiceNote() {
        let c = TriageClassifier.classify("rent is due on the 5th")
        XCTAssertEqual(c.type, .voiceNote)
        XCTAssertNil(c.rawMedia)
    }

    func testBareDomainWithoutSchemeIsVoiceNote() {
        // Siri transcribes "apple dot com" as apple.com; NSDataDetector would match it
        // with an inferred scheme. The explicit-scheme rule keeps it a voice note.
        let c = TriageClassifier.classify("apple.com")
        XCTAssertEqual(c.type, .voiceNote)
        XCTAssertNil(c.rawMedia)
    }

    func testDomainInsideProseIsVoiceNote() {
        let c = TriageClassifier.classify(
            "I was reading on apple.com about the new keyboard and thought we should buy one for the office"
        )
        XCTAssertEqual(c.type, .voiceNote)
    }

    func testURLBuriedInLongProseIsVoiceNote() {
        let c = TriageClassifier.classify(
            "This is a long thought about something with a link https://example.com buried inside it and lots more words after"
        )
        XCTAssertEqual(c.type, .voiceNote)
        XCTAssertNil(c.rawMedia)
    }

    func testEmptyTextIsVoiceNote() {
        let c = TriageClassifier.classify("")
        XCTAssertEqual(c.type, .voiceNote)
        XCTAssertNil(c.rawMedia)
    }

    func testWhitespaceOnlyIsVoiceNote() {
        let c = TriageClassifier.classify("  \n  ")
        XCTAssertEqual(c.type, .voiceNote)
    }
}
