import XCTest
@testable import Rapture

/// Compose-direct triage in `FileWriter`: full mode writes the final contract `.md`
/// straight into its classified subfolder (no transient `.txt`), raw mode remains
/// byte-identical to the pre-triage behavior.
@MainActor
final class FileWriterTriageTests: XCTestCase {

    private var root: URL!
    private var output: URL!
    private let fm = FileManager.default
    private var writer: FileWriter!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("fw-triage-\(UUID().uuidString)", isDirectory: true)
        output = root.appendingPathComponent("Rapture Notes", isDirectory: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        writer = FileWriter()
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
    }

    /// dateAppleNs 0 == Apple epoch, so `captured` is deterministically 2001-01-01T00:00:00Z.
    private func captured(text: String, attachments: [AttachmentRef] = []) -> CapturedMessage {
        CapturedMessage(
            event: MessageEvent(
                rowid: 1,
                guid: "guid-\(UUID().uuidString)",
                text: text,
                attributedBody: nil,
                dateAppleNs: 0,
                isFromMe: false,
                cacheHasAttachments: !attachments.isEmpty,
                service: "iMessage",
                handleId: "+15555550100",
                chatGuid: "iMessage;-;chat",
                chatStyle: 45,
                attachments: attachments
            ),
            decodedText: text,
            isCatchup: false
        )
    }

    private func mdFiles(in subfolder: String) throws -> [URL] {
        let dir = output.appendingPathComponent(subfolder, isDirectory: true)
        guard fm.fileExists(atPath: dir.path) else { return [] }
        return try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
    }

    // MARK: - Full mode

    func testVoiceNoteFilesIntoNotesWithContract() async throws {
        let result = await writer.write(captured(text: "rent is due on the 5th"), to: output, mode: .full)

        XCTAssertTrue(result.isSuccess)
        let notes = try mdFiles(in: "Notes")
        XCTAssertEqual(notes.count, 1)
        let name = notes[0].lastPathComponent
        XCTAssertTrue(name.hasSuffix(" Rent is due on the 5th.md"), "got \(name)")

        let contents = try String(contentsOf: notes[0], encoding: .utf8)
        XCTAssertTrue(contents.hasPrefix("---\ncaptured: 2001-01-01T00:00:00Z\nsource: rapture-mac\ntype: voice-note\n---\n\n"))
        XCTAssertTrue(contents.contains("rent is due on the 5th"))
        XCTAssertFalse(contents.contains("raw_media"), "voice notes carry no raw_media")
    }

    func testYouTubeLinkFilesIntoLinks() async throws {
        let url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        let result = await writer.write(captured(text: url), to: output, mode: .full)

        XCTAssertTrue(result.isSuccess)
        let links = try mdFiles(in: "Links")
        XCTAssertEqual(links.count, 1)
        XCTAssertTrue(links[0].lastPathComponent.hasSuffix(" YouTube dQw4w9WgXcQ.md"))

        let contents = try String(contentsOf: links[0], encoding: .utf8)
        XCTAssertTrue(contents.contains("type: youtube-link"))
        XCTAssertTrue(contents.contains("raw_media: \(url)"))
        XCTAssertTrue(try mdFiles(in: "Notes").isEmpty)
    }

    func testAttachmentFolderNamedAfterNoteWithMarkdownFooter() async throws {
        let source = root.appendingPathComponent("photo.heic")
        try Data([0xFF]).write(to: source)
        let attachment = AttachmentRef(sourcePath: source.path, mimeType: "image/heic", transferName: "photo.heic")

        let result = await writer.write(
            captured(text: "photo from the site visit", attachments: [attachment]),
            to: output,
            mode: .full
        )

        XCTAssertTrue(result.isSuccess)
        let note = try XCTUnwrap(mdFiles(in: "Notes").first)
        let base = note.deletingPathExtension().lastPathComponent
        let attachmentDir = output.appendingPathComponent("Notes/\(base)", isDirectory: true)
        XCTAssertTrue(fm.fileExists(atPath: attachmentDir.appendingPathComponent("photo.heic").path),
                      "attachment folder is the note's sibling, named after the note")

        let contents = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(contents.contains("Attachments:\n- [photo.heic](<\(base)/photo.heic>)"),
                      "footer links are markdown, relative to the note")
    }

    func testMdCollisionWalks() async throws {
        _ = await writer.write(captured(text: "same words"), to: output, mode: .full)
        _ = await writer.write(captured(text: "same words"), to: output, mode: .full)

        let notes = try mdFiles(in: "Notes")
        XCTAssertEqual(notes.count, 2, "second identical-title note gets a -1 suffix, never overwrites")
        let names = Set(notes.map(\.lastPathComponent))
        XCTAssertTrue(names.contains { $0.hasSuffix(" Same words.md") })
        XCTAssertTrue(names.contains { $0.hasSuffix(" Same words-1.md") })
    }

    // MARK: - Raw mode regression

    func testRawModeWritesISOTxtAtRoot() async throws {
        let result = await writer.write(captured(text: "hello"), to: output, mode: .raw)

        XCTAssertTrue(result.isSuccess)
        let txt = output.appendingPathComponent("2001-01-01T00-00-00Z.txt")
        XCTAssertEqual(try String(contentsOf: txt, encoding: .utf8), "hello",
                       "raw mode is the pre-triage behavior, byte-identical")
        XCTAssertFalse(fm.fileExists(atPath: output.appendingPathComponent("Notes").path),
                       "raw mode creates no triage subfolders")
    }
}
