import XCTest
@testable import Rapture

/// Pure parsing helpers of the real reader — the `-z` porcelain split and the
/// oldest-epoch pick. No subprocess, no filesystem.
final class SystemGitStateReaderTests: XCTestCase {

    func testParsePorcelainZReadsPaths() {
        let out = "?? new.md\u{0} M edited.md\u{0}"
        XCTAssertEqual(SystemGitStateReader.parsePorcelainZ(out), ["new.md", "edited.md"])
    }

    func testParsePorcelainZSkipsRenameOrigin() {
        // A rename entry is followed by its origin path as a separate -z token;
        // we keep the new (existing) path and skip the origin.
        let out = "R  new.md\u{0}old.md\u{0}"
        XCTAssertEqual(SystemGitStateReader.parsePorcelainZ(out), ["new.md"])
    }

    func testParsePorcelainZEmptyIsEmpty() {
        XCTAssertEqual(SystemGitStateReader.parsePorcelainZ(""), [])
    }

    func testOldestEpochPicksMinimum() {
        let date = SystemGitStateReader.oldestEpoch("1700000100\n1700000000\n1700000200\n")
        XCTAssertEqual(date, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testOldestEpochEmptyIsNil() {
        XCTAssertNil(SystemGitStateReader.oldestEpoch(""))
    }
}
