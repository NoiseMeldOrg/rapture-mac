import XCTest
@testable import Rapture

/// Goldens for the relocation footer rewrite: only a structurally well-formed
/// trailing footer is touched; prose lookalikes and non-matching folders pass
/// through unchanged (nil = leave the file alone).
final class CaptureContractFooterRewriteTests: XCTestCase {

    // MARK: - Markdown footer

    func testMarkdownFooterFolderRewritten() {
        let note = CaptureContract.compose(
            CaptureContract.Note(
                capturedAt: Date(timeIntervalSince1970: 0),
                source: .raptureMac,
                type: .voiceNote,
                rawMedia: nil,
                body: "groceries",
                rawBody: nil
            ),
            attachments: [CaptureContract.FooterAttachment(folder: "2026-07-10 X", filename: "photo.jpg")]
        )

        let rewritten = CaptureContract.rewriteFooterFolder(inMarkdown: note, from: "2026-07-10 X", to: "2026-07-10 X-1")

        XCTAssertNotNil(rewritten)
        XCTAssertTrue(rewritten!.contains("- [photo.jpg](<2026-07-10 X-1/photo.jpg>)"))
        XCTAssertFalse(rewritten!.contains("(<2026-07-10 X/photo.jpg>)"))
        XCTAssertTrue(rewritten!.contains("groceries"), "body untouched")
    }

    func testMarkdownRewriteRoundTripsCompose() {
        // Rewriting compose(folder A) must yield byte-exactly compose(folder B).
        let noteA = CaptureContract.compose(
            CaptureContract.Note(capturedAt: Date(timeIntervalSince1970: 0), source: nil, type: .voiceNote, rawMedia: nil, body: "b", rawBody: nil),
            attachments: [CaptureContract.FooterAttachment(folder: "A", filename: "f.jpg")]
        )
        let noteB = CaptureContract.compose(
            CaptureContract.Note(capturedAt: Date(timeIntervalSince1970: 0), source: nil, type: .voiceNote, rawMedia: nil, body: "b", rawBody: nil),
            attachments: [CaptureContract.FooterAttachment(folder: "B", filename: "f.jpg")]
        )
        XCTAssertEqual(CaptureContract.rewriteFooterFolder(inMarkdown: noteA, from: "A", to: "B"), noteB)
    }

    func testMarkdownProseLookalikeUntouched() {
        let text = "---\ntype: voice-note\n---\n\nremember the file\nAttachments:\nnot a real footer line\n"
        XCTAssertNil(CaptureContract.rewriteFooterFolder(inMarkdown: text, from: "X", to: "Y"))
    }

    func testMarkdownNonMatchingFolderReturnsNil() {
        let note = CaptureContract.compose(
            CaptureContract.Note(capturedAt: Date(timeIntervalSince1970: 0), source: nil, type: .voiceNote, rawMedia: nil, body: "b", rawBody: nil),
            attachments: [CaptureContract.FooterAttachment(folder: "Other", filename: "f.jpg")]
        )
        XCTAssertNil(CaptureContract.rewriteFooterFolder(inMarkdown: note, from: "X", to: "Y"),
                     "nothing to rewrite → leave the file alone")
    }

    func testMarkdownMissingFooterReturnsNil() {
        XCTAssertNil(CaptureContract.rewriteFooterFolder(inMarkdown: "just a body\n", from: "X", to: "Y"))
    }

    // MARK: - Plain-text footer

    func testPlainTextFooterFolderRewritten() {
        let text = "note body\n\nAttachments:\n- 2026-05-19T04-12-08Z/photo.jpg\n"
        let rewritten = CaptureContract.rewriteFooterFolder(
            inPlainText: text,
            from: "2026-05-19T04-12-08Z",
            to: "2026-05-19T04-12-08Z-1"
        )
        XCTAssertEqual(rewritten, "note body\n\nAttachments:\n- 2026-05-19T04-12-08Z-1/photo.jpg\n")
    }

    func testPlainTextNonMatchingFolderReturnsNil() {
        let text = "note body\n\nAttachments:\n- Other/photo.jpg\n"
        XCTAssertNil(CaptureContract.rewriteFooterFolder(inPlainText: text, from: "X", to: "Y"))
    }
}

@MainActor
final class TriageLedgerRemapTests: XCTestCase {

    func testRemappedRewritesOnlyMatchingPaths() {
        let now = Date()
        let entries = [
            TriagedEntry(sourceFilename: "a.txt", contentHash: "h1", mdRelativePath: "Notes/A.md", triagedAt: now),
            TriagedEntry(sourceFilename: "b.txt", contentHash: "h2", mdRelativePath: "Notes/B.md", triagedAt: now)
        ]
        let remapped = TriageLedger.remapped(entries, renamedNotes: ["Notes/A.md": "Notes/A-1.md"])
        XCTAssertEqual(remapped[0].mdRelativePath, "Notes/A-1.md")
        XCTAssertEqual(remapped[0].sourceFilename, "a.txt")
        XCTAssertEqual(remapped[0].contentHash, "h1")
        XCTAssertEqual(remapped[1], entries[1])
    }

    func testRemapPersistsThroughStateStore() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-remap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = StateStore(directory: dir)
        let ledger = TriageLedger(stateStore: store)
        ledger.record(sourceFilename: "a.txt", contentHash: "h1", mdRelativePath: "Notes/A.md")

        ledger.remap(["Notes/A.md": "Notes/A-1.md"])

        XCTAssertEqual(ledger.entry(sourceFilename: "a.txt")?.mdRelativePath, "Notes/A-1.md")
    }
}
