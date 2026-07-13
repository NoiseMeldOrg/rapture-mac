import XCTest
@testable import Rapture

/// Temp-dir integration tests for `TriageProcessor`: conversion of external root
/// `.txt` files into contract notes, ghost draining, the note-must-exist deletion
/// rule, attachment-folder moves, and deferral. Injected support directory — never
/// the live container (the `RelayProcessorTests` isolation pattern).
@MainActor
final class TriageProcessorTests: XCTestCase {

    private let fm = FileManager.default
    private var root: URL!
    private var output: URL!
    private var support: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("triage-proc-\(UUID().uuidString)", isDirectory: true)
        output = root.appendingPathComponent("Rapture Notes", isDirectory: true)
        support = root.appendingPathComponent("Support", isDirectory: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
    }

    private func makeAppState(mode: TriageMode = .full) -> AppState {
        let appState = AppState(supportDirectory: support)
        appState.settings.update {
            $0.outputFolder = output
            $0.paused = false
            $0.triageMode = mode
        }
        return appState
    }

    private func makeProcessor(appState: AppState) -> TriageProcessor {
        TriageProcessor(appState: appState, ledger: TriageLedger(stateStore: appState.state))
    }

    @discardableResult
    private func drop(_ name: String, body: String) throws -> URL {
        let url = output.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func process(_ names: [String], appState: AppState, processor: TriageProcessor) async {
        await processor.process(batch: TriageScanBatch(candidates: names.map {
            TriageCandidate(filename: $0)
        }))
    }

    private func mdFiles(in subfolder: String) throws -> [URL] {
        let dir = output.appendingPathComponent(subfolder, isDirectory: true)
        guard fm.fileExists(atPath: dir.path) else { return [] }
        return try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
    }

    // MARK: - Conversion

    func testConvertsPureISOTxtIntoNotesAndDeletesSource() async throws {
        let appState = makeAppState()
        let processor = makeProcessor(appState: appState)
        let source = try drop("2026-05-16T14-32-08Z.txt", body: "rent is due on the 5th")

        await process(["2026-05-16T14-32-08Z.txt"], appState: appState, processor: processor)

        let note = try XCTUnwrap(mdFiles(in: "Notes").first)
        let contents = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(contents.contains("captured: 2026-05-16T14:32:08Z"))
        XCTAssertTrue(contents.contains("source: rapture-mac"), "pure-ISO backlog names are Mac captures")
        XCTAssertTrue(contents.contains("rent is due on the 5th"))
        XCTAssertFalse(fm.fileExists(atPath: source.path), "source drained after durable write")
        XCTAssertTrue(appState.state.state.triagedRecords.contains { $0.sourceFilename == "2026-05-16T14-32-08Z.txt" })
    }

    func testRelayShapedBacklogKeepsIOSTitleAndSource() async throws {
        let appState = makeAppState()
        let processor = makeProcessor(appState: appState)
        try drop("2026-07-06T15-14-42Z Grocery Ideas.txt", body: "Milk and eggs")

        await process(["2026-07-06T15-14-42Z Grocery Ideas.txt"], appState: appState, processor: processor)

        let note = try XCTUnwrap(mdFiles(in: "Notes").first)
        XCTAssertTrue(note.lastPathComponent.hasSuffix(" Grocery Ideas.md"))
        XCTAssertTrue(try String(contentsOf: note, encoding: .utf8).contains("source: rapture-ios"))
    }

    func testYouTubeLinkFilesIntoLinks() async throws {
        let appState = makeAppState()
        let processor = makeProcessor(appState: appState)
        try drop("2026-07-01T10-00-00Z.txt", body: "https://youtu.be/dQw4w9WgXcQ")

        await process(["2026-07-01T10-00-00Z.txt"], appState: appState, processor: processor)

        let note = try XCTUnwrap(mdFiles(in: "Links").first)
        let contents = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(contents.contains("type: youtube-link"))
        XCTAssertTrue(contents.contains("raw_media: https://youtu.be/dQw4w9WgXcQ"))
    }

    func testFreeformNameOmitsSourceAndStillFiles() async throws {
        let appState = makeAppState()
        let processor = makeProcessor(appState: appState)
        try drop("random thought.txt", body: "a hand-dropped idea")

        await process(["random thought.txt"], appState: appState, processor: processor)

        let note = try XCTUnwrap(mdFiles(in: "Notes").first)
        let contents = try String(contentsOf: note, encoding: .utf8)
        XCTAssertFalse(contents.contains("source:"), "unknowable provenance is omitted, never guessed")
        XCTAssertTrue(contents.contains("a hand-dropped idea"))
    }

    // MARK: - Ledger rules

    func testGhostRedeliveryDrainsWithoutDuplicate() async throws {
        let appState = makeAppState()
        let processor = makeProcessor(appState: appState)
        try drop("2026-05-16T14-32-08Z.txt", body: "same bytes")
        await process(["2026-05-16T14-32-08Z.txt"], appState: appState, processor: processor)
        XCTAssertEqual(try mdFiles(in: "Notes").count, 1)

        // iCloud resurrects the identical file.
        let ghost = try drop("2026-05-16T14-32-08Z.txt", body: "same bytes")
        await process(["2026-05-16T14-32-08Z.txt"], appState: appState, processor: processor)

        XCTAssertEqual(try mdFiles(in: "Notes").count, 1, "no duplicate note")
        XCTAssertFalse(fm.fileExists(atPath: ghost.path), "ghost drained")
    }

    func testLedgerHitReTriagesWhenNoteWasDeleted() async throws {
        let appState = makeAppState()
        let processor = makeProcessor(appState: appState)
        try drop("2026-05-16T14-32-08Z.txt", body: "keep me")
        await process(["2026-05-16T14-32-08Z.txt"], appState: appState, processor: processor)
        let firstNote = try XCTUnwrap(mdFiles(in: "Notes").first)
        try fm.removeItem(at: firstNote)

        // The user re-drops the same source after deleting its note.
        let redrop = try drop("2026-05-16T14-32-08Z.txt", body: "keep me")
        await process(["2026-05-16T14-32-08Z.txt"], appState: appState, processor: processor)

        XCTAssertEqual(try mdFiles(in: "Notes").count, 1, "re-triaged instead of destroyed")
        XCTAssertFalse(fm.fileExists(atPath: redrop.path))
    }

    // MARK: - Attachments

    func testAttachmentFolderMovesWithNoteAndFooterRewrites() async throws {
        let appState = makeAppState()
        let processor = makeProcessor(appState: appState)
        let attachmentDir = output.appendingPathComponent("2026-06-01T10-00-00Z", isDirectory: true)
        try fm.createDirectory(at: attachmentDir, withIntermediateDirectories: true)
        try Data([0xFF]).write(to: attachmentDir.appendingPathComponent("photo.heic"))
        try drop("2026-06-01T10-00-00Z.txt", body: "site photo\n\nAttachments:\n- 2026-06-01T10-00-00Z/photo.heic\n")

        await process(["2026-06-01T10-00-00Z.txt"], appState: appState, processor: processor)

        let note = try XCTUnwrap(mdFiles(in: "Notes").first)
        let base = note.deletingPathExtension().lastPathComponent
        XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent("Notes/\(base)/photo.heic").path),
                      "attachment folder moved into the note's subfolder")
        XCTAssertFalse(fm.fileExists(atPath: attachmentDir.path), "old root folder is gone (moved, not copied)")
        let contents = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(contents.contains("Attachments:\n- [photo.heic](<\(base)/photo.heic>)"),
                      "footer rewritten to markdown links under the new folder name")
        XCTAssertFalse(contents.contains("## Raw"), "mechanical footer rewriting is not a formatting change")
    }

    func testDanglingFooterIsPreservedVerbatim() async throws {
        let appState = makeAppState()
        let processor = makeProcessor(appState: appState)
        try drop("2026-06-02T10-00-00Z.txt", body: "note\n\nAttachments:\n- missing-folder/gone.heic\n")

        await process(["2026-06-02T10-00-00Z.txt"], appState: appState, processor: processor)

        let note = try XCTUnwrap(mdFiles(in: "Notes").first)
        let contents = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(contents.contains("Attachments:\n- missing-folder/gone.heic"),
                      "a footer whose folder never synced is preserved as body text, not rewritten")
    }

    // MARK: - Deferral and guards

    func testRawModeDefersUntouched() async throws {
        let appState = makeAppState(mode: .raw)
        let processor = makeProcessor(appState: appState)
        let source = try drop("2026-05-16T14-32-08Z.txt", body: "leave me alone")

        await process(["2026-05-16T14-32-08Z.txt"], appState: appState, processor: processor)

        XCTAssertTrue(fm.fileExists(atPath: source.path))
        XCTAssertTrue(try mdFiles(in: "Notes").isEmpty)
    }

    func testPausedDefersUntouched() async throws {
        let appState = makeAppState()
        appState.settings.update { $0.paused = true }
        let processor = makeProcessor(appState: appState)
        let source = try drop("2026-05-16T14-32-08Z.txt", body: "later")

        await process(["2026-05-16T14-32-08Z.txt"], appState: appState, processor: processor)

        XCTAssertTrue(fm.fileExists(atPath: source.path))
        XCTAssertTrue(try mdFiles(in: "Notes").isEmpty)
    }

    func testVanishedCandidateIsSkippedQuietly() async throws {
        let appState = makeAppState()
        let processor = makeProcessor(appState: appState)

        await process(["never-existed.txt"], appState: appState, processor: processor)

        XCTAssertNil(appState.triageLastError)
        XCTAssertTrue(try mdFiles(in: "Notes").isEmpty)
    }

    func testEmptyFileFilesAsUntitledNote() async throws {
        let appState = makeAppState()
        let processor = makeProcessor(appState: appState)
        try drop("2026-05-16T14-32-08Z.txt", body: "")

        await process(["2026-05-16T14-32-08Z.txt"], appState: appState, processor: processor)

        let note = try XCTUnwrap(mdFiles(in: "Notes").first)
        XCTAssertTrue(note.lastPathComponent.hasSuffix(" Note.md"), "empty body falls back to the Note title")
    }
}
