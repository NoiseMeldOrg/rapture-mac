import XCTest
@testable import Rapture

/// The transcript-dispatch ledger's pure helpers and StateStore integration:
/// TTL expiry, capacity FIFO, fingerprint refresh, status update, remap,
/// retry reset, and the one-time seed. Mirrors `EnrichedLinkLedgerTests`.
@MainActor
final class TranscriptDispatchLedgerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(
        _ fp: String,
        path: String = "Links/2026-08-31 Video.md",
        status: TranscriptDispatchEntry.Status = .pending,
        at date: Date
    ) -> TranscriptDispatchEntry {
        TranscriptDispatchEntry(
            fingerprint: fp, url: "https://youtu.be/x", noteRelativePath: path,
            status: status, createdAt: date)
    }

    func testAppendAndLookup() {
        let entries = TranscriptDispatchLedger.appendEntry(
            into: [], entry: entry("yt:abc", at: now), now: now)
        let hit = TranscriptDispatchLedger.entry(in: entries, fingerprint: "yt:abc", now: now)
        XCTAssertEqual(hit?.status, .pending)
        XCTAssertNil(TranscriptDispatchLedger.entry(in: entries, fingerprint: "yt:other", now: now))
    }

    func testExpiredEntryIsNotALedgerHit() {
        let old = entry("yt:abc", at: now.addingTimeInterval(-TranscriptDispatchLedger.ttl - 1))
        XCTAssertNil(TranscriptDispatchLedger.entry(in: [old], fingerprint: "yt:abc", now: now))
    }

    func testAppendPrunesExpiredAndRefreshesFingerprint() {
        let stale = entry("yt:old", at: now.addingTimeInterval(-TranscriptDispatchLedger.ttl - 1))
        let existing = entry("yt:abc", status: .failed, at: now.addingTimeInterval(-100))
        let entries = TranscriptDispatchLedger.appendEntry(
            into: [stale, existing], entry: entry("yt:abc", at: now), now: now)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].status, .pending)
    }

    func testCapacityEvictsOldestFirst() {
        var entries: [TranscriptDispatchEntry] = []
        for i in 0..<(TranscriptDispatchLedger.capacity + 10) {
            entries = TranscriptDispatchLedger.appendEntry(
                into: entries, entry: entry("yt:\(i)", at: now.addingTimeInterval(TimeInterval(i))),
                now: now.addingTimeInterval(TimeInterval(i)))
        }
        XCTAssertEqual(entries.count, TranscriptDispatchLedger.capacity)
        XCTAssertEqual(entries.first?.fingerprint, "yt:10")
    }

    func testFailedResetToPendingKeepsAttemptsClearsError() {
        var failed = entry("yt:a", status: .failed, at: now)
        failed.attempts = 2
        failed.lastError = "boom"
        let done = entry("yt:b", status: .done, at: now)
        let reset = TranscriptDispatchLedger.failedResetToPending([failed, done])
        XCTAssertEqual(reset[0].status, .pending)
        XCTAssertEqual(reset[0].attempts, 2)
        XCTAssertNil(reset[0].lastError)
        XCTAssertEqual(reset[1], done, "non-failed entries untouched")
    }

    func testRemapRewritesOnlyMatchingPaths() {
        let a = entry("yt:a", path: "Links/A.md", at: now)
        let b = entry("yt:b", path: "Links/B.md", at: now)
        let remapped = TranscriptDispatchLedger.remapped([a, b], renamedNotes: ["Links/A.md": "Links/A-1.md"])
        XCTAssertEqual(remapped[0].noteRelativePath, "Links/A-1.md")
        XCTAssertEqual(remapped[0].fingerprint, "yt:a")
        XCTAssertEqual(remapped[1], b)
    }

    func testRecordPersistsThroughStateStore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dispatch-ledger-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(directory: dir)
        let ledger = TranscriptDispatchLedger(stateStore: store)

        ledger.append(entry("yt:abc", at: now))
        ledger.update(fingerprint: "yt:abc") { $0.status = .dispatched; $0.attempts = 1 }
        XCTAssertEqual(ledger.entry(fingerprint: "yt:abc")?.status, .dispatched)

        let reloaded = TranscriptDispatchLedger(stateStore: StateStore(directory: dir))
        XCTAssertEqual(reloaded.entry(fingerprint: "yt:abc")?.status, .dispatched)
        XCTAssertEqual(reloaded.entry(fingerprint: "yt:abc")?.attempts, 1)
    }

    func testSeedIfNeededIsIdempotentAndNeverClobbers() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dispatch-seed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = TranscriptDispatchLedger(stateStore: StateStore(directory: dir))

        ledger.seedIfNeeded(now: now)
        XCTAssertEqual(ledger.entry(fingerprint: TranscriptDispatchLedger.seedFingerprint)?.status, .done)
        XCTAssertEqual(ledger.records.count, 1)

        ledger.seedIfNeeded(now: now.addingTimeInterval(60))
        XCTAssertEqual(ledger.records.count, 1, "second seed is a no-op")

        // A real (non-done) entry for the seed fingerprint must never be clobbered.
        ledger.update(fingerprint: TranscriptDispatchLedger.seedFingerprint) { $0.status = .pending }
        ledger.seedIfNeeded(now: now.addingTimeInterval(120))
        XCTAssertEqual(ledger.entry(fingerprint: TranscriptDispatchLedger.seedFingerprint)?.status, .pending)
    }
}
