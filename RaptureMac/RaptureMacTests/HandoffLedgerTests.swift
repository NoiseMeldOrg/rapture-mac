import XCTest
@testable import Rapture

/// Pure-helper tests for the handoff dedup ledger (RelayFiledLedgerTests style),
/// plus the fingerprint composition rules.
final class HandoffLedgerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let datedFingerprint = "event|appointment at quest|2026-07-11T17:10:00Z"
    private let datelessFingerprint = "reminder|take out the trash|none"

    // MARK: - Fingerprint composition

    func testFingerprintNormalizesTitle() {
        let a = HandoffLedger.fingerprint(kind: .reminder, title: "Take out  the Trash.", dateKey: "none")
        let b = HandoffLedger.fingerprint(kind: .reminder, title: "take out the trash", dateKey: "none")
        XCTAssertEqual(a, b)
    }

    func testFingerprintSeparatesKinds() {
        let r = HandoffLedger.fingerprint(kind: .reminder, title: "call John", dateKey: "2026-07-11T18:00:00Z")
        let e = HandoffLedger.fingerprint(kind: .event, title: "call John", dateKey: "2026-07-11T18:00:00Z")
        XCTAssertNotEqual(r, e)
    }

    func testDateKeyForTimedResolvedIsUTCInstant() {
        let zone = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let date = calendar.date(from: DateComponents(year: 2026, month: 7, day: 11, hour: 13, minute: 10))!
        let resolved = HandoffDateParser.Resolved(date: date, hasTime: true, hasExplicitDay: true, consumedRanges: [])
        XCTAssertEqual(HandoffLedger.dateKey(for: resolved, timeZone: zone), "2026-07-11T17:10:00Z")
    }

    func testDateKeyForDateOnlyIsLocalCalendarDay() {
        let zone = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let date = calendar.date(from: DateComponents(year: 2026, month: 7, day: 11))!
        let resolved = HandoffDateParser.Resolved(date: date, hasTime: false, hasExplicitDay: true, consumedRanges: [])
        XCTAssertEqual(HandoffLedger.dateKey(for: resolved, timeZone: zone), "2026-07-11")
    }

    func testDateKeyForNilIsDateless() {
        XCTAssertEqual(HandoffLedger.dateKey(for: nil, timeZone: .current), HandoffLedger.datelessDateKey)
    }

    // MARK: - Windows

    func testDatedEntryMatchesInsideTTL() {
        let entries = HandoffLedger.appendEntry(into: [], fingerprint: datedFingerprint, now: now)
        let nearTTL = now.addingTimeInterval(HandoffLedger.ttl - 1)
        XCTAssertTrue(HandoffLedger.matches(entries: entries, fingerprint: datedFingerprint, now: nearTTL))
        let afterTTL = now.addingTimeInterval(HandoffLedger.ttl + 1)
        XCTAssertFalse(HandoffLedger.matches(entries: entries, fingerprint: datedFingerprint, now: afterTTL))
    }

    func testDatelessEntryMatchesOnlyInsideShortWindow() {
        let entries = HandoffLedger.appendEntry(into: [], fingerprint: datelessFingerprint, now: now)
        let insideWindow = now.addingTimeInterval(HandoffLedger.datelessWindow - 1)
        XCTAssertTrue(HandoffLedger.matches(entries: entries, fingerprint: datelessFingerprint, now: insideWindow))
        // A genuinely repeated dateless chore re-dictated next week must create again.
        let afterWindow = now.addingTimeInterval(HandoffLedger.datelessWindow + 1)
        XCTAssertFalse(HandoffLedger.matches(entries: entries, fingerprint: datelessFingerprint, now: afterWindow))
    }

    func testExpiredDatelessEntryPrunedOnAppend() {
        let old = HandoffLedger.appendEntry(into: [], fingerprint: datelessFingerprint, now: now)
        let later = now.addingTimeInterval(HandoffLedger.datelessWindow + 1)
        let appended = HandoffLedger.appendEntry(into: old, fingerprint: datedFingerprint, now: later)
        XCTAssertEqual(appended.count, 1)
        XCTAssertEqual(appended.first?.fingerprint, datedFingerprint)
    }

    // MARK: - Shape (capacity, refresh)

    func testCapacityFIFOEviction() {
        var entries: [HandoffEntry] = []
        for i in 0..<(HandoffLedger.capacity + 10) {
            entries = HandoffLedger.appendEntry(into: entries, fingerprint: "reminder|item \(i)|none", now: now)
        }
        XCTAssertEqual(entries.count, HandoffLedger.capacity)
        XCTAssertFalse(HandoffLedger.matches(entries: entries, fingerprint: "reminder|item 0|none", now: now))
        XCTAssertTrue(HandoffLedger.matches(entries: entries, fingerprint: "reminder|item \(HandoffLedger.capacity + 9)|none", now: now))
    }

    func testReappendRefreshesInsteadOfDuplicating() {
        let first = HandoffLedger.appendEntry(into: [], fingerprint: datedFingerprint, now: now)
        let later = now.addingTimeInterval(3600)
        let second = HandoffLedger.appendEntry(into: first, fingerprint: datedFingerprint, now: later)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.first?.createdAt, later)
    }
}
