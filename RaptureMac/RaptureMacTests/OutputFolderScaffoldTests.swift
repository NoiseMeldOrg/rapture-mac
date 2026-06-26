import XCTest
@testable import Rapture

/// Opt-in starter scaffold (GOAL 3). Must seed only a genuinely fresh folder and never
/// disturb one the user already curates.
final class OutputFolderScaffoldTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("scaffold-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
    }

    private func makeDir(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    func testSeedsEmptyFolder() throws {
        let folder = try makeDir("notes")

        XCTAssertTrue(OutputFolderScaffold.seedIfEligible(folder: folder, fileManager: fm))

        XCTAssertTrue(exists(folder.appendingPathComponent("CLAUDE.md")))
        XCTAssertTrue(exists(folder.appendingPathComponent("processed")))
        XCTAssertTrue(exists(folder.appendingPathComponent("in-progress")))
    }

    func testDoesNotSeedWhenClaudeMdPresent() throws {
        let folder = try makeDir("notes")
        // Folder is non-empty AND has a CLAUDE.md — both reasons to skip.
        try "my rules".write(to: folder.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)

        XCTAssertFalse(OutputFolderScaffold.seedIfEligible(folder: folder, fileManager: fm))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("CLAUDE.md"), encoding: .utf8), "my rules",
                       "existing CLAUDE.md must be left byte-for-byte")
        XCTAssertFalse(exists(folder.appendingPathComponent("processed")))
    }

    func testDoesNotSeedNonEmptyFolderWithoutClaudeMd() throws {
        let folder = try makeDir("notes")
        try "a note".write(to: folder.appendingPathComponent("2026-06-25T00-00-00Z.txt"), atomically: true, encoding: .utf8)

        XCTAssertFalse(OutputFolderScaffold.seedIfEligible(folder: folder, fileManager: fm),
                       "a folder with notes is not fresh, even without a CLAUDE.md")
        XCTAssertFalse(exists(folder.appendingPathComponent("CLAUDE.md")))
        XCTAssertFalse(exists(folder.appendingPathComponent("processed")))
    }

    func testIsIdempotent() throws {
        let folder = try makeDir("notes")

        XCTAssertTrue(OutputFolderScaffold.seedIfEligible(folder: folder, fileManager: fm))
        let claude = folder.appendingPathComponent("CLAUDE.md")
        let firstContents = try String(contentsOf: claude, encoding: .utf8)

        // Second call: folder is no longer empty / already has CLAUDE.md → no-op, no overwrite.
        XCTAssertFalse(OutputFolderScaffold.seedIfEligible(folder: folder, fileManager: fm))
        XCTAssertEqual(try String(contentsOf: claude, encoding: .utf8), firstContents)
    }

    func testNoOpOnMissingFolder() {
        let missing = root.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertFalse(OutputFolderScaffold.seedIfEligible(folder: missing, fileManager: fm))
    }

    func testTemplateHasNoUserSpecificPaths() {
        let t = OutputFolderScaffold.templateClaudeMd
        // The template must stay generic — no machine/user/repo specifics baked in.
        XCTAssertFalse(t.contains("/Users/"), "template must not embed a home path")
        XCTAssertFalse(t.lowercased().contains("agentic-os"), "template must not name a specific repo")
        XCTAssertFalse(t.contains("/Volumes/"), "template must not embed a volume path")
        XCTAssertTrue(t.contains("processed/"), "template should still describe the folder layout")
    }
}
