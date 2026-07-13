import XCTest
@testable import Rapture

/// Pure-helper tests for `TriageLedger` — no StateStore, no filesystem, no clock.
final class TriageLedgerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(
        name: String,
        hash: String = "h",
        mdPath: String = "Notes/x.md",
        ago: TimeInterval = 0
    ) -> TriagedEntry {
        TriagedEntry(
            sourceFilename: name,
            contentHash: hash,
            mdRelativePath: mdPath,
            triagedAt: now.addingTimeInterval(-ago)
        )
    }

    // MARK: - appendEntry

    func testAppendAddsEntry() {
        let result = TriageLedger.appendEntry(
            into: [], sourceFilename: "a.txt", contentHash: "h1", mdRelativePath: "Notes/a.md", now: now
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.sourceFilename, "a.txt")
        XCTAssertEqual(result.first?.mdRelativePath, "Notes/a.md")
    }

    func testAppendRefreshesExistingFilenameInsteadOfDuplicating() {
        let existing = [entry(name: "a.txt", hash: "old", mdPath: "Notes/old.md", ago: 60)]
        let result = TriageLedger.appendEntry(
            into: existing, sourceFilename: "a.txt", contentHash: "new", mdRelativePath: "Links/new.md", now: now
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.contentHash, "new")
        XCTAssertEqual(result.first?.mdRelativePath, "Links/new.md")
    }

    func testAppendDropsExpiredEntries() {
        let existing = [entry(name: "old.txt", ago: TriageLedger.ttl + 1)]
        let result = TriageLedger.appendEntry(
            into: existing, sourceFilename: "b.txt", contentHash: "h", mdRelativePath: "Notes/b.md", now: now
        )
        XCTAssertEqual(result.map(\.sourceFilename), ["b.txt"])
    }

    func testAppendEvictsOldestBeyondCapacity() {
        let existing = (0..<TriageLedger.capacity).map { entry(name: "n\($0).txt", ago: 1) }
        let result = TriageLedger.appendEntry(
            into: existing, sourceFilename: "newest.txt", contentHash: "h", mdRelativePath: "Notes/n.md", now: now
        )
        XCTAssertEqual(result.count, TriageLedger.capacity)
        XCTAssertNil(result.first(where: { $0.sourceFilename == "n0.txt" }), "oldest entry evicted")
        XCTAssertEqual(result.last?.sourceFilename, "newest.txt")
    }

    // MARK: - entry lookup

    func testEntryMatchesFilenameAndHash() {
        let entries = [entry(name: "a.txt", hash: "h1")]
        XCTAssertNotNil(TriageLedger.entry(in: entries, sourceFilename: "a.txt", contentHash: "h1", now: now))
        XCTAssertNil(
            TriageLedger.entry(in: entries, sourceFilename: "a.txt", contentHash: "different", now: now),
            "same name with different bytes is a new capture, not a ghost"
        )
        XCTAssertNil(TriageLedger.entry(in: entries, sourceFilename: "b.txt", contentHash: "h1", now: now))
    }

    func testEntryFilenameOnlyLookupIgnoresHash() {
        let entries = [entry(name: "a.txt", hash: "h1", mdPath: "Notes/a.md")]
        let found = TriageLedger.entry(in: entries, sourceFilename: "a.txt", contentHash: nil, now: now)
        XCTAssertEqual(found?.mdRelativePath, "Notes/a.md")
    }

    func testEntryIgnoresExpired() {
        let entries = [entry(name: "a.txt", ago: TriageLedger.ttl + 1)]
        XCTAssertNil(TriageLedger.entry(in: entries, sourceFilename: "a.txt", contentHash: nil, now: now))
    }

    // MARK: - hash

    func testHashIsStableSHA256Hex() {
        let data = Data("hello".utf8)
        XCTAssertEqual(
            TriageLedger.hash(of: data),
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
        XCTAssertNotEqual(TriageLedger.hash(of: data), TriageLedger.hash(of: Data("hello!".utf8)))
    }
}
