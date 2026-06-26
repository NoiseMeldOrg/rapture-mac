import XCTest
@testable import Rapture

/// The single guarded deletion primitive. These lock the invariant that a directory
/// holding *any* data is never removed — the rule the 2026-06-22 incident violated.
final class FileSafetyTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("filesafety-\(UUID().uuidString)", isDirectory: true)
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

    func testRemovesEmptyDirectory() throws {
        let dir = try makeDir("empty")
        XCTAssertTrue(FileSafety.removeIfEmpty(dir, fileManager: fm))
        XCTAssertFalse(fm.fileExists(atPath: dir.path))
    }

    func testRefusesDirectoryWithAFile() throws {
        let dir = try makeDir("has-file")
        try "x".write(to: dir.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        XCTAssertFalse(FileSafety.removeIfEmpty(dir, fileManager: fm), "non-empty must not be removed")
        XCTAssertTrue(fm.fileExists(atPath: dir.path))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("note.txt"), encoding: .utf8), "x")
    }

    func testRefusesDirectoryHoldingOnlyADotfile() throws {
        let dir = try makeDir("has-dotfile")
        try "h".write(to: dir.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)

        XCTAssertFalse(FileSafety.removeIfEmpty(dir, fileManager: fm), "a lone dotfile still counts as non-empty")
        XCTAssertTrue(fm.fileExists(atPath: dir.path))
    }

    func testRefusesDirectoryWithASubfolder() throws {
        let dir = try makeDir("has-sub")
        _ = try makeDir("has-sub/processed")

        XCTAssertFalse(FileSafety.removeIfEmpty(dir, fileManager: fm))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("processed").path))
    }

    func testNoOpOnMissingPath() {
        let missing = root.appendingPathComponent("nope", isDirectory: true)
        XCTAssertFalse(FileSafety.removeIfEmpty(missing, fileManager: fm))
    }

    func testNoOpOnAFile() throws {
        let file = root.appendingPathComponent("a-file.txt")
        try "data".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertFalse(FileSafety.removeIfEmpty(file, fileManager: fm), "a file is not an empty directory")
        XCTAssertTrue(fm.fileExists(atPath: file.path), "the file must be left untouched")
    }

    func testIsEmptyDirectory() throws {
        let empty = try makeDir("e")
        let full = try makeDir("f")
        try "x".write(to: full.appendingPathComponent("a"), atomically: true, encoding: .utf8)

        XCTAssertTrue(FileSafety.isEmptyDirectory(empty, fileManager: fm))
        XCTAssertFalse(FileSafety.isEmptyDirectory(full, fileManager: fm))
        XCTAssertFalse(FileSafety.isEmptyDirectory(root.appendingPathComponent("missing"), fileManager: fm))
    }
}
