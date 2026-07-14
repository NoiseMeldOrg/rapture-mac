import XCTest
@testable import Rapture

/// Golden tests for artifact compose, the `Media:` append (including its
/// structural interplay with the `Attachments:` footer), and the enriched
/// title sanitizer.
final class EnrichmentArtifactTests: XCTestCase {

    // MARK: - Artifact compose

    func testComposeGolden() {
        let composed = EnrichmentArtifact.compose(
            source: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            fetchedAt: Date(timeIntervalSince1970: 1_784_000_000),
            captureNoteFilename: "2026-07-13 Real Video Title.md",
            kind: .youtubeTranscript,
            body: "First paragraph.\n\nSecond paragraph.")
        XCTAssertEqual(composed, """
        ---
        source: https://www.youtube.com/watch?v=dQw4w9WgXcQ
        fetched: \(CaptureContract.iso8601(Date(timeIntervalSince1970: 1_784_000_000)))
        capture: ../2026-07-13 Real Video Title.md
        type: youtube-transcript
        ---

        First paragraph.

        Second paragraph.

        """)
    }

    func testComposeArticleKind() {
        let composed = EnrichmentArtifact.compose(
            source: "https://example.com/post",
            fetchedAt: Date(timeIntervalSince1970: 0),
            captureNoteFilename: "2026-07-13 Post.md",
            kind: .articleExtract,
            body: "Body.")
        XCTAssertTrue(composed.contains("type: article-extract"))
    }

    // MARK: - Media append

    private let noteWithoutFooter = """
    ---
    captured: 2026-07-13T15:00:00Z
    type: youtube-link
    raw_media: https://youtu.be/dQw4w9WgXcQ
    ---

    https://youtu.be/dQw4w9WgXcQ
    """

    func testAppendsAtEndWhenNoFooter() throws {
        let result = try XCTUnwrap(EnrichmentArtifact.appendingMediaLink(
            toMarkdown: noteWithoutFooter + "\n",
            label: "Real Video Title",
            target: "Media/2026-07-13 Real Video Title.md"))
        let expectedSuffix = "\n\nMedia:\n- [Real Video Title](<Media/2026-07-13 Real Video Title.md>)\n"
        XCTAssertTrue(result.hasSuffix(expectedSuffix), "got: \(result)")
    }

    func testInsertsBeforeAttachmentsFooter() throws {
        let note = noteWithoutFooter + "\n\nAttachments:\n- [photo.png](<2026-07-13 YouTube dQw4w9WgXcQ/photo.png>)\n"
        let result = try XCTUnwrap(EnrichmentArtifact.appendingMediaLink(
            toMarkdown: note, label: "Title", target: "Media/2026-07-13 Title.md"))

        let mediaIndex = try XCTUnwrap(result.range(of: "Media:\n"))
        let footerIndex = try XCTUnwrap(result.range(of: "Attachments:\n"))
        XCTAssertLessThan(mediaIndex.lowerBound, footerIndex.lowerBound, "Media block precedes the footer")
    }

    func testFooterStillRewritableAfterAppend() throws {
        // The load-bearing structural invariant: appending must never break
        // CaptureContract.rewriteFooterFolder's parse of the trailing footer.
        let note = noteWithoutFooter + "\n\nAttachments:\n- [photo.png](<OldFolder/photo.png>)\n"
        let appended = try XCTUnwrap(EnrichmentArtifact.appendingMediaLink(
            toMarkdown: note, label: "Title", target: "Media/2026-07-13 Title.md"))
        let rewritten = CaptureContract.rewriteFooterFolder(inMarkdown: appended, from: "OldFolder", to: "NewFolder")
        XCTAssertNotNil(rewritten, "footer rewrite must survive the Media append")
        XCTAssertTrue(try XCTUnwrap(rewritten).contains("(<NewFolder/photo.png>)"))
        XCTAssertTrue(try XCTUnwrap(rewritten).contains("- [Title](<Media/2026-07-13 Title.md>)"), "media link untouched")
    }

    func testAppendIsIdempotent() throws {
        let once = try XCTUnwrap(EnrichmentArtifact.appendingMediaLink(
            toMarkdown: noteWithoutFooter + "\n", label: "T", target: "Media/T.md"))
        XCTAssertNil(EnrichmentArtifact.appendingMediaLink(toMarkdown: once, label: "T", target: "Media/T.md"))
    }

    // MARK: - Enriched title sanitizer

    func testEnrichedTitleSanitizesFilesystemHostiles() {
        XCTAssertEqual(
            TitleDeriver.enrichedLinkTitle(from: "Swift 6: What/Why \0 Explained"),
            "Swift 6 What Why Explained")
    }

    func testEnrichedTitleKeepsCasingNoWordCap() {
        let title = "A Deep Dive into the SwiftUI Observation Framework on macOS"
        XCTAssertEqual(TitleDeriver.enrichedLinkTitle(from: title), title)
    }

    func testEnrichedTitleTruncatesAtWordBoundary() throws {
        let long = "This title is deliberately far longer than sixty characters to force the boundary truncation rule"
        let result = try XCTUnwrap(TitleDeriver.enrichedLinkTitle(from: long))
        XCTAssertLessThanOrEqual(result.count, 60)
        XCTAssertFalse(result.hasSuffix(" "))
    }

    func testEnrichedTitleEmptyAndDotsReturnNil() {
        XCTAssertNil(TitleDeriver.enrichedLinkTitle(from: "   "))
        XCTAssertNil(TitleDeriver.enrichedLinkTitle(from: "..."))
    }
}
