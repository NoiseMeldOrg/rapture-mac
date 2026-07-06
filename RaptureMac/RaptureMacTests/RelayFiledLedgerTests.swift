import XCTest
@testable import Rapture

/// Pure-helper tests for the relay dedup ledger (same style as ContentDedupCacheTests).
final class RelayFiledLedgerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let filename = "2026-07-06T15-14-42Z Grocery Ideas.txt"

    func testContainsAfterAppend() {
        let entries = RelayFiledLedger.appendEntry(into: [], relayFilename: filename, now: now)
        XCTAssertTrue(RelayFiledLedger.matches(entries: entries, relayFilename: filename, now: now))
        XCTAssertFalse(RelayFiledLedger.matches(entries: entries, relayFilename: "other.txt", now: now))
    }

    func testExpiredEntryDoesNotMatchAndIsPrunedOnAppend() {
        let old = RelayFiledLedger.appendEntry(into: [], relayFilename: filename, now: now)
        let afterTTL = now.addingTimeInterval(RelayFiledLedger.ttl + 1)

        XCTAssertFalse(RelayFiledLedger.matches(entries: old, relayFilename: filename, now: afterTTL))

        let appended = RelayFiledLedger.appendEntry(into: old, relayFilename: "new.txt", now: afterTTL)
        XCTAssertEqual(appended.count, 1, "the expired entry must be pruned")
        XCTAssertEqual(appended.first?.relayFilename, "new.txt")
    }

    func testCapacityFIFOEviction() {
        var entries: [RelayFiledEntry] = []
        for i in 0..<(RelayFiledLedger.capacity + 10) {
            entries = RelayFiledLedger.appendEntry(into: entries, relayFilename: "note-\(i).txt", now: now)
        }
        XCTAssertEqual(entries.count, RelayFiledLedger.capacity)
        XCTAssertFalse(RelayFiledLedger.matches(entries: entries, relayFilename: "note-0.txt", now: now),
                       "oldest entries are evicted first")
        XCTAssertTrue(RelayFiledLedger.matches(entries: entries, relayFilename: "note-\(RelayFiledLedger.capacity + 9).txt", now: now))
    }

    func testReappendRefreshesInsteadOfDuplicating() {
        let first = RelayFiledLedger.appendEntry(into: [], relayFilename: filename, now: now)
        let later = now.addingTimeInterval(3600)
        let second = RelayFiledLedger.appendEntry(into: first, relayFilename: filename, now: later)

        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.first?.filedAt, later, "re-append must refresh the timestamp")
    }
}
