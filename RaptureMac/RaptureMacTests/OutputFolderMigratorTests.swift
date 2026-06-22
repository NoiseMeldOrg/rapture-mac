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

    func testMergeKeepsDestinationMarkdownAndDisambiguatesNotes() throws {
        let old = try makeDir("old")
        try write("incoming-claude", to: old.appendingPathComponent("CLAUDE.md"))
        try write("incoming-note", to: old.appendingPathComponent("note.txt"))
        try write("incoming-processed", to: old.appendingPathComponent("processed/p.txt"))

        let new = try makeDir("new")
        try write("existing-claude", to: new.appendingPathComponent("CLAUDE.md"))
        try write("existing-note", to: new.appendingPathComponent("note.txt"))
        try write("existing-processed", to: new.appendingPathComponent("processed/q.txt"))

        try migrator.migrate(from: old, to: new, strategy: .move)

        // .md collision keeps the destination copy.
        XCTAssertEqual(try read(new.appendingPathComponent("CLAUDE.md")), "existing-claude")

        // Note collision: destination preserved, incoming disambiguated — both survive.
        XCTAssertEqual(try read(new.appendingPathComponent("note.txt")), "existing-note")
        XCTAssertEqual(try read(new.appendingPathComponent("note-1.txt")), "incoming-note")

        // Directory collision merges children (no overwrite of the existing one).
        XCTAssertEqual(try read(new.appendingPathComponent("processed/q.txt")), "existing-processed")
        XCTAssertEqual(try read(new.appendingPathComponent("processed/p.txt")), "incoming-processed")

        // The skipped (kept-destination) CLAUDE.md remains in the old folder, so the old
        // folder is NOT removed — we never delete a directory that still holds data.
        XCTAssertTrue(exists(old), "old folder kept because a skipped .md still lives there")
        XCTAssertEqual(try read(old.appendingPathComponent("CLAUDE.md")), "incoming-claude")
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
