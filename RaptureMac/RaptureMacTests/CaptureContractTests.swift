import XCTest
@testable import Rapture

/// Golden tests for the capture contract: exact Markdown output, filename shape,
/// backlog filename parsing, and footer parse rules. Expected values are literals
/// from the PRD's contract spec — never recomputed.
final class CaptureContractTests: XCTestCase {

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    // MARK: - compose: golden outputs

    func testVoiceNoteWithSourceGolden() {
        let note = CaptureContract.Note(
            capturedAt: date("2026-07-13T15:22:08Z"),
            source: .raptureMac,
            type: .voiceNote,
            rawMedia: nil,
            body: "Rent is due on the 5th",
            rawBody: nil
        )
        XCTAssertEqual(CaptureContract.compose(note), """
        ---
        captured: 2026-07-13T15:22:08Z
        source: rapture-mac
        type: voice-note
        ---

        Rent is due on the 5th

        """)
    }

    func testLinkNoteWithoutSourceGolden() {
        let note = CaptureContract.Note(
            capturedAt: date("2026-07-13T15:22:08Z"),
            source: nil,
            type: .articleLink,
            rawMedia: "https://example.com/article",
            body: "https://example.com/article",
            rawBody: nil
        )
        XCTAssertEqual(CaptureContract.compose(note), """
        ---
        captured: 2026-07-13T15:22:08Z
        type: article-link
        raw_media: https://example.com/article
        ---

        https://example.com/article

        """)
    }

    func testAttachmentsFooterUsesMarkdownLinks() {
        let note = CaptureContract.Note(
            capturedAt: date("2026-07-13T15:22:08Z"),
            source: .raptureIOS,
            type: .voiceNote,
            rawMedia: nil,
            body: "Photo from the site visit",
            rawBody: nil
        )
        let composed = CaptureContract.compose(note, attachments: [
            CaptureContract.FooterAttachment(folder: "2026-07-13 Photo from the site visit", filename: "photo.heic")
        ])
        XCTAssertTrue(composed.hasSuffix("""
        Photo from the site visit

        Attachments:
        - [photo.heic](<2026-07-13 Photo from the site visit/photo.heic>)

        """), "footer must use angle-bracket markdown links relative to the note")
    }

    func testEmptyBodyWithAttachmentsSkipsBlankBody() {
        let note = CaptureContract.Note(
            capturedAt: date("2026-07-13T15:22:08Z"),
            source: nil,
            type: .voiceNote,
            rawMedia: nil,
            body: "",
            rawBody: nil
        )
        let composed = CaptureContract.compose(note, attachments: [
            CaptureContract.FooterAttachment(folder: "F", filename: "a.m4a")
        ])
        XCTAssertTrue(composed.contains("---\n\nAttachments:\n- [a.m4a](<F/a.m4a>)\n"))
    }

    func testDifferingRawBodyProducesRawSection() {
        let note = CaptureContract.Note(
            capturedAt: date("2026-07-13T15:22:08Z"),
            source: .raptureIOS,
            type: .voiceNote,
            rawMedia: nil,
            body: "Formatted body.",
            rawBody: "formatted body"
        )
        let composed = CaptureContract.compose(note)
        XCTAssertTrue(composed.contains("Formatted body.\n\n## Raw\n\nformatted body\n"))
    }

    func testIdenticalRawBodyOmitsRawSection() {
        let note = CaptureContract.Note(
            capturedAt: date("2026-07-13T15:22:08Z"),
            source: nil,
            type: .voiceNote,
            rawMedia: nil,
            body: "same",
            rawBody: "same"
        )
        XCTAssertFalse(CaptureContract.compose(note).contains("## Raw"))
    }

    // MARK: - filenameBase: local calendar date

    func testFilenameUsesLocalDateOfCapture() {
        // 02:00 UTC on July 13 is 22:00 on July 12 in New York (UTC-4 in July).
        let base = CaptureContract.filenameBase(
            title: "Rent is due on the 5th",
            capturedAt: date("2026-07-13T02:00:00Z"),
            timeZone: TimeZone(identifier: "America/New_York")!
        )
        XCTAssertEqual(base, "2026-07-12 Rent is due on the 5th")
    }

    func testFilenameInUTC() {
        let base = CaptureContract.filenameBase(
            title: "Note",
            capturedAt: date("2026-07-13T02:00:00Z"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(base, "2026-07-13 Note")
    }

    // MARK: - parseSourceFilename: backlog shapes

    func testPureISOFilenameIsMacCapture() {
        let info = CaptureContract.parseSourceFilename("2026-05-16T14-32-08Z.txt")
        XCTAssertEqual(info.capturedAt, date("2026-05-16T14:32:08Z"))
        XCTAssertEqual(info.source, .raptureMac)
        XCTAssertNil(info.relayTitle)
    }

    func testPureISOWithCollisionSuffixIsMacCapture() {
        let info = CaptureContract.parseSourceFilename("2026-05-16T14-32-08Z-3.txt")
        XCTAssertEqual(info.capturedAt, date("2026-05-16T14:32:08Z"))
        XCTAssertEqual(info.source, .raptureMac)
    }

    func testISOPlusTitleIsIOSRelayCapture() {
        let info = CaptureContract.parseSourceFilename("2026-07-06T15-14-42Z Grocery Ideas.txt")
        XCTAssertEqual(info.capturedAt, date("2026-07-06T15:14:42Z"))
        XCTAssertEqual(info.source, .raptureIOS)
        XCTAssertEqual(info.relayTitle, "Grocery Ideas")
    }

    func testFreeformFilenameIsUnknown() {
        let info = CaptureContract.parseSourceFilename("random note.txt")
        XCTAssertNil(info.capturedAt)
        XCTAssertNil(info.source)
        XCTAssertNil(info.relayTitle)
    }

    func testStampWithGarbageRemainderIsUnknown() {
        let info = CaptureContract.parseSourceFilename("2026-05-16T14-32-08Zjunk.txt")
        XCTAssertNil(info.source)
        XCTAssertNil(info.capturedAt)
    }

    // MARK: - parseFooter

    func testParsesTrailingFooter() {
        let parsed = CaptureContract.parseFooter("hello\n\nAttachments:\n- 2026/x.heic\n")
        XCTAssertEqual(parsed?.bodyWithoutFooter, "hello")
        XCTAssertEqual(parsed?.attachments, [CaptureContract.FooterAttachment(folder: "2026", filename: "x.heic")])
    }

    func testParsesFooterOnlyBody() {
        let parsed = CaptureContract.parseFooter("Attachments:\n- F/a.m4a\n")
        XCTAssertEqual(parsed?.bodyWithoutFooter, "")
        XCTAssertEqual(parsed?.attachments, [CaptureContract.FooterAttachment(folder: "F", filename: "a.m4a")])
    }

    func testFolderNamesWithSpacesParse() {
        let parsed = CaptureContract.parseFooter(
            "note\n\nAttachments:\n- 2026-07-06T15-14-42Z Grocery Ideas/audio.m4a\n"
        )
        XCTAssertEqual(parsed?.attachments, [
            CaptureContract.FooterAttachment(folder: "2026-07-06T15-14-42Z Grocery Ideas", filename: "audio.m4a")
        ])
    }

    func testMultipleAttachmentLines() {
        let parsed = CaptureContract.parseFooter("x\n\nAttachments:\n- F/a.heic\n- F/b.heic\n")
        XCTAssertEqual(parsed?.attachments.count, 2)
    }

    func testTextWithoutFooterReturnsNil() {
        XCTAssertNil(CaptureContract.parseFooter("just a plain note"))
    }

    func testMalformedFooterLineDisqualifiesTheBlock() {
        XCTAssertNil(
            CaptureContract.parseFooter("x\n\nAttachments:\n- not a path line\n"),
            "a trailing block with a line that isn't folder/file is prose, not a footer"
        )
    }

    func testMidTextAttachmentsMentionIsNotAFooter() {
        XCTAssertNil(CaptureContract.parseFooter("see Attachments: below for details\nmore prose"))
    }
}
