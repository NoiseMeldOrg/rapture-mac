import XCTest
@testable import Rapture

/// The dedup identity rules, table-driven: YouTube = video ID (query params
/// vary, the ID doesn't); articles = normalized URL.
final class LinkFingerprintTests: XCTestCase {

    // MARK: - YouTube

    func testYouTubeWatchURL() {
        XCTAssertEqual(
            LinkFingerprint.fingerprint(rawMedia: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", type: .youtubeLink),
            "yt:dQw4w9WgXcQ")
    }

    func testYouTubeShortURLAndQueryNoiseCollapseToSameFingerprint() {
        let variants = [
            "https://youtu.be/dQw4w9WgXcQ",
            "https://youtu.be/dQw4w9WgXcQ?si=abc123",
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s&feature=share",
            "https://m.youtube.com/watch?v=dQw4w9WgXcQ"
        ]
        for variant in variants {
            XCTAssertEqual(
                LinkFingerprint.fingerprint(rawMedia: variant, type: .youtubeLink),
                "yt:dQw4w9WgXcQ", variant)
        }
    }

    func testYouTubeShortsAndLiveForms() {
        XCTAssertEqual(
            LinkFingerprint.fingerprint(rawMedia: "https://www.youtube.com/shorts/abc123XYZ_-", type: .youtubeLink),
            "yt:abc123XYZ_-")
        XCTAssertEqual(
            LinkFingerprint.fingerprint(rawMedia: "https://www.youtube.com/live/TJ359NeY__A", type: .youtubeLink),
            "yt:TJ359NeY__A")
    }

    func testYouTubeWithoutVideoIDIsNotEnrichable() {
        XCTAssertNil(LinkFingerprint.fingerprint(rawMedia: "https://www.youtube.com/", type: .youtubeLink))
        XCTAssertNil(LinkFingerprint.fingerprint(rawMedia: "https://www.youtube.com/feed/subscriptions", type: .youtubeLink))
    }

    // MARK: - Articles

    func testArticleHostAndSchemeLowercased() {
        XCTAssertEqual(
            LinkFingerprint.fingerprint(rawMedia: "HTTPS://Example.COM/Post", type: .articleLink),
            "url:https://example.com/Post")
    }

    func testArticlePathCasePreserved() {
        // Paths are case-sensitive on most servers; only scheme/host normalize.
        XCTAssertEqual(
            LinkFingerprint.normalizedArticleURL(URL(string: "https://example.com/Blog/My-Post")!),
            "https://example.com/Blog/My-Post")
    }

    func testArticleFragmentDropped() {
        XCTAssertEqual(
            LinkFingerprint.normalizedArticleURL(URL(string: "https://example.com/post#section-2")!),
            "https://example.com/post")
    }

    func testArticleTrackingParamsDropped() {
        XCTAssertEqual(
            LinkFingerprint.normalizedArticleURL(
                URL(string: "https://example.com/post?utm_source=x&utm_medium=social&fbclid=abc&gclid=def&igshid=ghi")!),
            "https://example.com/post")
    }

    func testArticleMeaningfulParamsKeptInOrder() {
        XCTAssertEqual(
            LinkFingerprint.normalizedArticleURL(URL(string: "https://example.com/story?id=42&page=2&utm_campaign=x")!),
            "https://example.com/story?id=42&page=2")
    }

    func testArticleTrailingSlashStripped() {
        XCTAssertEqual(
            LinkFingerprint.normalizedArticleURL(URL(string: "https://example.com/post/")!),
            "https://example.com/post")
    }

    func testArticleRootPathEquivalence() {
        XCTAssertEqual(
            LinkFingerprint.normalizedArticleURL(URL(string: "https://example.com/")!),
            LinkFingerprint.normalizedArticleURL(URL(string: "https://example.com")!))
    }

    func testNonHTTPSchemesAreNotEnrichable() {
        XCTAssertNil(LinkFingerprint.normalizedArticleURL(URL(string: "ftp://example.com/file")!))
        XCTAssertNil(LinkFingerprint.fingerprint(rawMedia: "mailto:someone@example.com", type: .articleLink))
    }

    func testUnparseableURLIsNotEnrichable() {
        XCTAssertNil(LinkFingerprint.fingerprint(rawMedia: "not a url at all", type: .articleLink))
    }

    func testVoiceNoteTypeNeverFingerprinted() {
        XCTAssertNil(LinkFingerprint.fingerprint(rawMedia: "https://example.com/post", type: .voiceNote))
    }
}
