import XCTest
@testable import Rapture

final class OutputFolderMigratorTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default
    private var migrator: OutputFolderMigrator!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("migrator-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        migrator = OutputFolderMigrator(fileManager: fm)
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
    }

    // MARK: - Fixture helpers

    private func makeDir(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func write(_ contents: String, to url: URL) throws -> URL {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func exists(_ url: URL) -> Bool {
        fm.fileExists(atPath: url.path)
    }

    // MARK: - Same-volume rename

    func testSameVolumeMovePreservesTreeIncludingDotfiles() throws {
        let old = try makeDir("old")
        try write("first", to: old.appendingPathComponent("note1.txt"))
        try write("hidden", to: old.appendingPathComponent(".secret"))
        try write("img", to: old.appendingPathComponent("note1/photo.jpg"))
        try write("done", to: old.appendingPathComponent("processed/2026-06/old.txt"))

        let new = try makeDir("new")
        try migrator.migrate(from: old, to: new, strategy: .move)

        XCTAssertEqual(try read(new.appendingPathComponent("note1.txt")), "first")
        XCTAssertEqual(try read(new.appendingPathComponent(".secret")), "hidden")
        XCTAssertEqual(try read(new.appendingPathComponent("note1/photo.jpg")), "img")
        XCTAssertEqual(try read(new.appendingPathComponent("processed/2026-06/old.txt")), "done")

        // A clean move empties the old folder, so it is removed entirely.
        XCTAssertFalse(exists(old), "emptied old folder should be removed after a clean move")
    }

    // MARK: - Cross-volume copy + verify + delete (forced on one volume via strategy)

    func testCopyVerifyDeleteMovesContentAndRemovesSource() throws {
        let old = try makeDir("old")
        try write("alpha", to: old.appendingPathComponent("a.txt"))
        try write("beta", to: old.appendingPathComponent("sub/b.txt"))

        let new = try makeDir("new")
        try migrator.migrate(from: old, to: new, strategy: .copyVerifyDelete)

        XCTAssertEqual(try read(new.appendingPathComponent("a.txt")), "alpha")
        XCTAssertEqual(try read(new.appendingPathComponent("sub/b.txt")), "beta")
        XCTAssertFalse(exists(old.appendingPathComponent("a.txt")), "source file removed after verified copy")
        XCTAssertFalse(exists(old.appendingPathComponent("sub")), "source subtree removed after verified copy")
    }

    // MARK: - Merge with collisions

    func testMergeKeepsDestinationClaudeMdAndDisambiguatesNotes() throws {
        let old = try makeDir("old")
        try write("incoming-claude", to: old.appendingPathComponent("CLAUDE.md"))
        try write("incoming-note", to: old.appendingPathComponent("note.txt"))
        try write("incoming-md-note", to: old.appendingPathComponent("Notes/2026-07-10 Groceries.md"))
        try write("incoming-processed", to: old.appendingPathComponent("processed/p.txt"))

        let new = try makeDir("new")
        try write("existing-claude", to: new.appendingPathComponent("CLAUDE.md"))
        try write("existing-note", to: new.appendingPathComponent("note.txt"))
        try write("existing-md-note", to: new.appendingPathComponent("Notes/2026-07-10 Groceries.md"))
        try write("existing-processed", to: new.appendingPathComponent("processed/q.txt"))

        try migrator.migrate(from: old, to: new, strategy: .move)

        // CLAUDE.md collision keeps the destination copy.
        XCTAssertEqual(try read(new.appendingPathComponent("CLAUDE.md")), "existing-claude")

        // Note collision: destination preserved, incoming disambiguated — both survive.
        XCTAssertEqual(try read(new.appendingPathComponent("note.txt")), "existing-note")
        XCTAssertEqual(try read(new.appendingPathComponent("note-1.txt")), "incoming-note")

        // Ordinary .md files are *notes*, not config: a colliding triaged note must
        // disambiguate like any note, never be silently stranded in the old folder.
        XCTAssertEqual(try read(new.appendingPathComponent("Notes/2026-07-10 Groceries.md")), "existing-md-note")
        XCTAssertEqual(try read(new.appendingPathComponent("Notes/2026-07-10 Groceries-1.md")), "incoming-md-note")

        // Directory collision merges children (no overwrite of the existing one).
        XCTAssertEqual(try read(new.appendingPathComponent("processed/q.txt")), "existing-processed")
        XCTAssertEqual(try read(new.appendingPathComponent("processed/p.txt")), "incoming-processed")

        // The skipped (kept-destination) CLAUDE.md remains in the old folder, so the old
        // folder is NOT removed — we never delete a directory that still holds data.
        XCTAssertTrue(exists(old), "old folder kept because a skipped CLAUDE.md still lives there")
        XCTAssertEqual(try read(old.appendingPathComponent("CLAUDE.md")), "incoming-claude")
    }

    // MARK: - Note + attachment-folder pairs (M2: lockstep rename)

    /// The M1-flagged edge: both folders hold the same note name WITH populated
    /// attachment folders. Pre-M2, the note took `-1` but its attachment folder
    /// merged into the destination note's folder — cross-wiring the two notes'
    /// attachments and dangling the renamed note's footer.
    func testPairCollisionRenamesNoteAndAttachmentFolderInLockstep() throws {
        let noteName = "2026-07-10 Groceries"
        let incomingBody = "---\ncaptured: 2026-07-10T14:00:00Z\ntype: voice-note\n---\n\ngroceries\n\nAttachments:\n- [incoming.jpg](<\(noteName)/incoming.jpg>)\n"

        let old = try makeDir("old")
        try write(incomingBody, to: old.appendingPathComponent("Notes/\(noteName).md"))
        try write("incoming-img", to: old.appendingPathComponent("Notes/\(noteName)/incoming.jpg"))

        let new = try makeDir("new")
        try write("existing-note", to: new.appendingPathComponent("Notes/\(noteName).md"))
        try write("existing-img", to: new.appendingPathComponent("Notes/\(noteName)/existing.jpg"))

        let report = try migrator.migrate(from: old, to: new, strategy: .move)

        // Destination pair untouched.
        XCTAssertEqual(try read(new.appendingPathComponent("Notes/\(noteName).md")), "existing-note")
        XCTAssertEqual(try read(new.appendingPathComponent("Notes/\(noteName)/existing.jpg")), "existing-img")
        XCTAssertFalse(exists(new.appendingPathComponent("Notes/\(noteName)/incoming.jpg")),
                       "incoming attachments must not merge into the other note's folder")

        // Incoming pair renamed in lockstep, footer rewritten.
        let renamedNote = new.appendingPathComponent("Notes/\(noteName)-1.md")
        XCTAssertEqual(try read(new.appendingPathComponent("Notes/\(noteName)-1/incoming.jpg")), "incoming-img")
        XCTAssertTrue(try read(renamedNote).contains("- [incoming.jpg](<\(noteName)-1/incoming.jpg>)"),
                      "footer must point at the renamed folder")

        // Rename reported for the ledger remap.
        XCTAssertEqual(report.renamedNotes["Notes/\(noteName).md"], "Notes/\(noteName)-1.md")
    }

    func testPairWithOnlyDirCollidingStillRenamesLockstep() throws {
        let old = try makeDir("old")
        try write("note", to: old.appendingPathComponent("X.md"))
        try write("img", to: old.appendingPathComponent("X/a.jpg"))

        let new = try makeDir("new")
        // Only the directory name is taken at the destination.
        try write("other", to: new.appendingPathComponent("X/other.jpg"))

        try migrator.migrate(from: old, to: new, strategy: .move)

        XCTAssertEqual(try read(new.appendingPathComponent("X-1.md")), "note")
        XCTAssertEqual(try read(new.appendingPathComponent("X-1/a.jpg")), "img")
        XCTAssertEqual(try read(new.appendingPathComponent("X/other.jpg")), "other")
    }

    func testTxtPairFooterRewrittenOnLockstepRename() throws {
        let base = "2026-05-19T04-12-08Z"
        let old = try makeDir("old")
        try write("note body\n\nAttachments:\n- \(base)/photo.jpg\n", to: old.appendingPathComponent("\(base).txt"))
        try write("img", to: old.appendingPathComponent("\(base)/photo.jpg"))

        let new = try makeDir("new")
        try write("existing", to: new.appendingPathComponent("\(base).txt"))
        try write("existing-img", to: new.appendingPathComponent("\(base)/keep.jpg"))

        try migrator.migrate(from: old, to: new, strategy: .move)

        XCTAssertEqual(try read(new.appendingPathComponent("\(base)-1/photo.jpg")), "img")
        XCTAssertTrue(try read(new.appendingPathComponent("\(base)-1.txt")).contains("- \(base)-1/photo.jpg"))
    }

    func testPairSurvivesCrossVolumeCopyPath() throws {
        let old = try makeDir("old")
        try write("note", to: old.appendingPathComponent("Y.md"))
        try write("img", to: old.appendingPathComponent("Y/a.jpg"))

        let new = try makeDir("new")
        try write("existing", to: new.appendingPathComponent("Y.md"))

        try migrator.migrate(from: old, to: new, strategy: .copyVerifyDelete)

        XCTAssertEqual(try read(new.appendingPathComponent("Y-1.md")), "note")
        XCTAssertEqual(try read(new.appendingPathComponent("Y-1/a.jpg")), "img")
        XCTAssertFalse(exists(old.appendingPathComponent("Y.md")), "source removed after verified copy")
    }

    func testSingleNoteCollisionReportedForLedgerRemap() throws {
        let old = try makeDir("old")
        try write("incoming", to: old.appendingPathComponent("Notes/2026-07-10 Idea.md"))

        let new = try makeDir("new")
        try write("existing", to: new.appendingPathComponent("Notes/2026-07-10 Idea.md"))

        let report = try migrator.migrate(from: old, to: new, strategy: .move)

        XCTAssertEqual(report.renamedNotes["Notes/2026-07-10 Idea.md"], "Notes/2026-07-10 Idea-1.md")
    }

    func testCleanMigrationReportsNoRenames() throws {
        let old = try makeDir("old")
        try write("note", to: old.appendingPathComponent("Notes/a.md"))
        let new = try makeDir("new")

        let report = try migrator.migrate(from: old, to: new, strategy: .move)

        XCTAssertTrue(report.renamedNotes.isEmpty)
    }

    // MARK: - uniqueURL extension semantics (M2 fix)

    func testCollidingDirectoryWithPeriodsInNameKeepsFullName() throws {
        let old = try makeDir("old")
        try write("incoming", to: old.appendingPathComponent("Notes v1.2/a.txt"))

        let new = try makeDir("new")
        // A file (not dir) at the destination path forces the type-mismatch
        // collision branch instead of dir-into-dir merge.
        try write("existing-file", to: new.appendingPathComponent("Notes v1.2"))

        try migrator.migrate(from: old, to: new, strategy: .move)

        XCTAssertEqual(try read(new.appendingPathComponent("Notes v1.2-1/a.txt")), "incoming",
                       "directories are extensionless: never Notes v1-1.2")
        XCTAssertFalse(exists(new.appendingPathComponent("Notes v1-1.2")))
    }

    // MARK: - No-op when unchanged

    func testNoOpWhenSourceEqualsDestination() throws {
        let folder = try makeDir("notes")
        try write("keep", to: folder.appendingPathComponent("a.txt"))

        try migrator.migrate(from: folder, to: folder, strategy: .move)

        XCTAssertEqual(try read(folder.appendingPathComponent("a.txt")), "keep")
    }

    // MARK: - Nested-path guards

    func testRefusesNewNestedInsideOld() throws {
        let old = try makeDir("old")
        try write("x", to: old.appendingPathComponent("a.txt"))
        let new = old.appendingPathComponent("inner", isDirectory: true)

        XCTAssertThrowsError(try migrator.migrate(from: old, to: new, strategy: .move))
        XCTAssertEqual(try read(old.appendingPathComponent("a.txt")), "x", "nothing moved on refusal")
    }

    func testRefusesOldNestedInsideNew() throws {
        let new = try makeDir("new")
        let old = try makeDir("new/inner")
        try write("x", to: old.appendingPathComponent("a.txt"))

        XCTAssertThrowsError(try migrator.migrate(from: old, to: new, strategy: .move))
        XCTAssertEqual(try read(old.appendingPathComponent("a.txt")), "x", "nothing moved on refusal")
    }

    // MARK: - Failure leaves source intact

    func testFailureLeavesSourceIntact() throws {
        let old = try makeDir("old")
        try write("one", to: old.appendingPathComponent("a.txt"))
        try write("two", to: old.appendingPathComponent("b.txt"))

        let new = try makeDir("new")
        // Make the destination read-only so the move fails.
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: new.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: new.path) }

        XCTAssertThrowsError(try migrator.migrate(from: old, to: new, strategy: .move))

        XCTAssertEqual(try read(old.appendingPathComponent("a.txt")), "one")
        XCTAssertEqual(try read(old.appendingPathComponent("b.txt")), "two")
    }

    // MARK: - URL + sidecar persist across simulated relaunch

    func testOutputFolderURLSurvivesCodableRoundTrip() throws {
        let folder = root.appendingPathComponent("Rapture Notes", isDirectory: true)
        let settings = Settings(outputFolder: folder)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(settings)

        // Simulated relaunch: decode a fresh Settings from the persisted JSON.
        let reloaded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(reloaded.outputFolder?.path, folder.path)
    }

    func testSidecarWritesResolvedPath() throws {
        let folder = try makeDir("Rapture Notes")
        let sidecar = root.appendingPathComponent("output-folder.path")

        try OutputFolderSidecar.write(folder, to: sidecar)

        let written = try read(sidecar)
        XCTAssertEqual(written, OutputFolderSidecar.contents(for: folder))
        XCTAssertFalse(written.hasSuffix("\n"), "sidecar should have no trailing newline")
    }
}
