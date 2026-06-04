import XCTest
@testable import Rapture

final class ContentDedupCacheTests: XCTestCase {

    // MARK: - matches() basics

    func testEmptyCacheNeverMatches() {
        let now = Date()
        XCTAssertFalse(ContentDedupCache.matches(
            entries: [],
            handle: "+15555550199",
            text: "rent is due on the 5th",
            attachmentCount: 0,
            now: now
        ))
    }

    func testIdenticalEntryMatches() {
        let now = Date()
        let entries = ContentDedupCache.appendEntry(
            into: [],
            handle: "+15555550199",
            text: "rent is due on the 5th",
            attachmentCount: 0,
            now: now
        )
        XCTAssertTrue(ContentDedupCache.matches(
            entries: entries,
            handle: "+15555550199",
            text: "rent is due on the 5th",
            attachmentCount: 0,
            now: now.addingTimeInterval(1)
        ))
    }

    func testTextNormalizationLetsIdenticalRepliesMatch() {
        // EchoGuard.normalize handles case, whitespace, smart quotes. Two reads of
        // the same message text that differ only in those dimensions must match.
        let now = Date()
        let entries = ContentDedupCache.appendEntry(
            into: [],
            handle: "+15555550199",
            text: "  Rent is due on the 5th  ",
            attachmentCount: 0,
            now: now
        )
        XCTAssertTrue(ContentDedupCache.matches(
            entries: entries,
            handle: "+15555550199",
            text: "rent is due on the 5th",
            attachmentCount: 0,
            now: now
        ))
    }

    func testHandleNormalizationStripsPrefix() {
        // SelfHandleResolver.normalize strips `E:` / `p:` and lowercases.
        let now = Date()
        let entries = ContentDedupCache.appendEntry(
            into: [],
            handle: "E:+15555550199",
            text: "hello",
            attachmentCount: 0,
            now: now
        )
        XCTAssertTrue(ContentDedupCache.matches(
            entries: entries,
            handle: "+15555550199",
            text: "hello",
            attachmentCount: 0,
            now: now
        ))
    }

    func testDifferentHandleDoesNotMatch() {
        let now = Date()
        let entries = ContentDedupCache.appendEntry(
            into: [],
            handle: "+15555550199",
            text: "hello",
            attachmentCount: 0,
            now: now
        )
        XCTAssertFalse(ContentDedupCache.matches(
            entries: entries,
            handle: "+15555550123",
            text: "hello",
            attachmentCount: 0,
            now: now
        ))
    }

    func testDifferentAttachmentCountDoesNotMatch() {
        let now = Date()
        let entries = ContentDedupCache.appendEntry(
            into: [],
            handle: "+15555550199",
            text: "look at this",
            attachmentCount: 1,
            now: now
        )
        XCTAssertFalse(ContentDedupCache.matches(
            entries: entries,
            handle: "+15555550199",
            text: "look at this",
            attachmentCount: 2,
            now: now
        ))
    }

    // MARK: - TTL

    func testExpiredEntryDoesNotMatch() {
        let now = Date()
        let entries = ContentDedupCache.appendEntry(
            into: [],
            handle: "+15555550199",
            text: "hello",
            attachmentCount: 0,
            now: now
        )
        let later = now.addingTimeInterval(ContentDedupCache.ttl + 1)
        XCTAssertFalse(ContentDedupCache.matches(
            entries: entries,
            handle: "+15555550199",
            text: "hello",
            attachmentCount: 0,
            now: later
        ))
    }

    func testTTLIsSevenDays() {
        // Sentinel — the observed iCloud-replay window was ~30 hours; bumping below
        // 7 days re-opens the daily-15:16 cluster the user reported. Bumping above
        // bloats state.json without catching more cases.
        XCTAssertEqual(ContentDedupCache.ttl, 7 * 24 * 60 * 60)
    }

    // MARK: - appendEntry behavior

    func testAppendPrunesExpiredEntries() {
        let now = Date()
        let oldEntries = ContentDedupCache.appendEntry(
            into: [],
            handle: "+15555550199",
            text: "old message",
            attachmentCount: 0,
            now: now
        )
        let later = now.addingTimeInterval(ContentDedupCache.ttl + 1)
        let merged = ContentDedupCache.appendEntry(
            into: oldEntries,
            handle: "+15555550199",
            text: "new message",
            attachmentCount: 0,
            now: later
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.normalizedText, "new message")
    }

    func testAppendDeduplicatesRefreshingExpiry() {
        // Caller normally checks contains() first, but if track() is called
        // twice for the same key we want one entry with the later expiry,
        // not two stacked entries.
        let t0 = Date()
        let t1 = t0.addingTimeInterval(60)
        let entries0 = ContentDedupCache.appendEntry(
            into: [],
            handle: "+15555550199",
            text: "hello",
            attachmentCount: 0,
            now: t0
        )
        let entries1 = ContentDedupCache.appendEntry(
            into: entries0,
            handle: "+15555550199",
            text: "hello",
            attachmentCount: 0,
            now: t1
        )
        XCTAssertEqual(entries1.count, 1)
        XCTAssertEqual(entries1.first?.expiresAt, t1.addingTimeInterval(ContentDedupCache.ttl))
    }

    func testAppendEvictsOldestWhenCapacityExceeded() {
        let now = Date()
        var entries: [CaptureHashEntry] = []
        for i in 0..<(ContentDedupCache.capacity + 5) {
            entries = ContentDedupCache.appendEntry(
                into: entries,
                handle: "+15555550199",
                text: "msg-\(i)",
                attachmentCount: 0,
                now: now
            )
        }
        XCTAssertEqual(entries.count, ContentDedupCache.capacity)
        // FIFO eviction: the first 5 should be gone, the last one should be present.
        XCTAssertEqual(entries.first?.normalizedText, "msg-5")
        XCTAssertEqual(entries.last?.normalizedText, "msg-\(ContentDedupCache.capacity + 4)")
    }

    func testCapacityValueIsFiveHundred() {
        // Sentinel — at ~200 captures/week this is the steady-state size with
        // 7-day TTL. Dropping it risks evicting still-valid entries during a
        // burst; raising it bloats state.json.
        XCTAssertEqual(ContentDedupCache.capacity, 500)
    }

    // MARK: - The user's reported scenario

    func testICloudReplayPatternIsCaught() {
        // The reported failure: same Siri-dictated message arrives multiple times
        // via iCloud cross-device sync over a multi-day window, each delivery with
        // a different GUID. Without content dedup, each becomes its own file +
        // its own "✅ Saved" reply.
        let captured = Date()
        let entries = ContentDedupCache.appendEntry(
            into: [],
            handle: "+15555550199",
            text: "https://youtube.com/shorts/4kAbzzkxYag",
            attachmentCount: 0,
            now: captured
        )
        // Same message redelivers ~30 hours later (the observed lag from the
        // June 2 → June 3 cluster).
        let nextDayWake = captured.addingTimeInterval(30 * 60 * 60)
        XCTAssertTrue(ContentDedupCache.matches(
            entries: entries,
            handle: "+15555550199",
            text: "https://youtube.com/shorts/4kAbzzkxYag",
            attachmentCount: 0,
            now: nextDayWake
        ))
    }
}
