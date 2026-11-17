import XCTest
@testable import Rapture

final class ContentDedupCacheTests: XCTestCase {

    /// A fixed send time for the tests that are not about the send time.
    private let sent = Date(timeIntervalSince1970: 1_790_000_000)

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    // MARK: - matches() basics

    func testEmptyCacheNeverMatches() {
        let now = Date()
        XCTAssertFalse(ContentDedupCache.matches(
            entries: [],
            handle: "+15555550199",
            text: "rent is due on the 5th",
            attachmentCount: 0,
            sentAt: sent,
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
            sentAt: sent,
            now: now
        )
        XCTAssertTrue(ContentDedupCache.matches(
            entries: entries,
            handle: "+15555550199",
            text: "rent is due on the 5th",
            attachmentCount: 0,
            sentAt: sent,
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
            sentAt: sent,
            now: now
        )
        XCTAssertTrue(ContentDedupCache.matches(
            entries: entries,
            handle: "+15555550199",
            text: "rent is due on the 5th",
            attachmentCount: 0,
            sentAt: sent,
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
            sentAt: sent,
            now: now
        )
        XCTAssertTrue(ContentDedupCache.matches(
            entries: entries,
            handle: "+15555550199",
            text: "hello",
            attachmentCount: 0,
            sentAt: sent,
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
            sentAt: sent,
            now: now
        )
        XCTAssertFalse(ContentDedupCache.matches(
            entries: entries,
            handle: "+15555550123",
            text: "hello",
            attachmentCount: 0,
            sentAt: sent,
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
            sentAt: sent,
            now: now
        )
        XCTAssertFalse(ContentDedupCache.matches(
            entries: entries,
            handle: "+15555550199",
            text: "look at this",
            attachmentCount: 2,
            sentAt: sent,
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
            sentAt: sent,
            now: now
        )
        let later = now.addingTimeInterval(ContentDedupCache.ttl + 1)
        XCTAssertFalse(ContentDedupCache.matches(
            entries: entries,
            handle: "+15555550199",
            text: "hello",
            attachmentCount: 0,
            sentAt: sent,
            now: later
        ))
    }

    func testTTLIsNinetyDays() {
        // Sentinel — seven days was not enough: iCloud replayed a note 10.5 days
        // after the original (2026-09-22 → 2026-10-02) and it filed twice. Bumping
        // below 90 days re-opens that; entries are capped by `capacity` regardless.
        // `isReplay` also reads this value to date entries that have no `sentAt`.
        XCTAssertEqual(ContentDedupCache.ttl, 90 * 24 * 60 * 60)
    }

    // MARK: - appendEntry behavior

    func testAppendPrunesExpiredEntries() {
        let now = Date()
        let oldEntries = ContentDedupCache.appendEntry(
            into: [],
            handle: "+15555550199",
            text: "old message",
            attachmentCount: 0,
            sentAt: sent,
            now: now
        )
        let later = now.addingTimeInterval(ContentDedupCache.ttl + 1)
        let merged = ContentDedupCache.appendEntry(
            into: oldEntries,
            handle: "+15555550199",
            text: "new message",
            attachmentCount: 0,
            sentAt: sent,
            now: later
        )
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.normalizedText, "new message")
    }

    func testAppendDeduplicatesRefreshingExpiry() {
        // Caller normally checks contains() first, but if track() is called
        // twice for the same message we want one entry with the later expiry,
        // not two stacked entries.
        let t0 = Date()
        let t1 = t0.addingTimeInterval(60)
        let entries0 = ContentDedupCache.appendEntry(
            into: [],
            handle: "+15555550199",
            text: "hello",
            attachmentCount: 0,
            sentAt: sent,
            now: t0
        )
        let entries1 = ContentDedupCache.appendEntry(
            into: entries0,
            handle: "+15555550199",
            text: "hello",
            attachmentCount: 0,
            sentAt: sent.addingTimeInterval(1),
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
                sentAt: sent,
                now: now
            )
        }
        XCTAssertEqual(entries.count, ContentDedupCache.capacity)
        // FIFO eviction: the first 5 should be gone, the last one should be present.
        XCTAssertEqual(entries.first?.normalizedText, "msg-5")
        XCTAssertEqual(entries.last?.normalizedText, "msg-\(ContentDedupCache.capacity + 4)")
    }

    func testCapacityValueIsFiveHundred() {
        // Sentinel — the cap, not the 90-day TTL, bounds state.json. Dropping it
        // risks evicting still-valid entries during a burst; raising it bloats
        // state.json.
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
            sentAt: captured,
            now: captured
        )
        // Same message redelivers ~30 hours later (the observed lag from the
        // June 2 → June 3 cluster). Its send time is the original's, 1 to 2 s off.
        let nextDayWake = captured.addingTimeInterval(30 * 60 * 60)
        XCTAssertTrue(ContentDedupCache.matches(
            entries: entries,
            handle: "+15555550199",
            text: "https://youtube.com/shorts/4kAbzzkxYag",
            attachmentCount: 0,
            sentAt: captured.addingTimeInterval(2),
            now: nextDayWake
        ))
    }

    // MARK: - Send time: a replay or a new note

    func testSameWordsSentTheNextDayAreANewNote() {
        // 2026-11-17: "Test" was captured on 2026-11-16. "Test" sent the next
        // morning filed nothing and got no reply, because the guard matched on
        // the words alone.
        let first = date("2026-11-16T17:12:01Z")
        let entries = ContentDedupCache.appendEntry(
            into: [], handle: "+15555550199", text: "Test", attachmentCount: 0,
            sentAt: first, now: first.addingTimeInterval(2)
        )
        XCTAssertFalse(ContentDedupCache.matches(
            entries: entries, handle: "+15555550199", text: "Test", attachmentCount: 0,
            sentAt: date("2026-11-17T13:19:00Z"), now: date("2026-11-17T13:19:02Z")
        ))
    }

    func testALateReplayHasTheSendTimeOfTheOriginal() {
        // The real case behind the 90-day TTL: a note sent 2026-09-22T13:31:13Z
        // came again on 2026-10-02, and the copy had the same `captured` second.
        let sentAt = date("2026-09-22T13:31:13Z")
        let entries = ContentDedupCache.appendEntry(
            into: [], handle: "+15555550199", text: "FigJam online app to create graphs and charts",
            attachmentCount: 0, sentAt: sentAt, now: sentAt.addingTimeInterval(3)
        )
        XCTAssertTrue(ContentDedupCache.matches(
            entries: entries, handle: "+15555550199", text: "FigJam online app to create graphs and charts",
            attachmentCount: 0, sentAt: sentAt, now: date("2026-10-03T02:42:00Z")
        ))
    }

    func testReplayWindow() {
        let original = date("2026-11-16T17:12:01Z")
        let entry = CaptureHashEntry(
            handleNormalized: "+15555550199", normalizedText: "test", attachmentCount: 0,
            expiresAt: original.addingTimeInterval(ContentDedupCache.ttl), sentAt: original
        )
        let cases: [(offset: TimeInterval, replay: Bool)] = [
            (0, true), (2, true), (-2, true),
            (ContentDedupCache.replayWindow, true), (-ContentDedupCache.replayWindow, true),
            (ContentDedupCache.replayWindow + 1, false), (-ContentDedupCache.replayWindow - 1, false),
            (3600, false), (-3600, false), (86_400, false),
        ]
        for c in cases {
            XCTAssertEqual(
                ContentDedupCache.isReplay(of: entry, sentAt: original.addingTimeInterval(c.offset)),
                c.replay, "offset \(c.offset) s"
            )
        }
    }

    func testReplayWindowIsOneMinute() {
        // Sentinel. Smaller risks a second note from a replay whose clock is a
        // few seconds off. Larger drops more notes that the author sent twice.
        XCTAssertEqual(ContentDedupCache.replayWindow, 60)
    }

    func testEntryWithoutASendTimeUsesItsCaptureTime() {
        // An entry from before `sentAt` existed. This is the shape of the "test"
        // entry on the machine where the bug was found: expiry 2027-02-14T17:12:03Z,
        // so the capture was at 2026-11-16T17:12:03Z.
        let entry = CaptureHashEntry(
            handleNormalized: "+15555550199", normalizedText: "test", attachmentCount: 0,
            expiresAt: date("2027-02-14T17:12:03Z"), sentAt: nil
        )
        let now = date("2026-11-17T13:19:02Z")
        // A replay: sent before that capture.
        XCTAssertTrue(ContentDedupCache.matches(
            entries: [entry], handle: "+15555550199", text: "Test", attachmentCount: 0,
            sentAt: date("2026-11-16T17:12:01Z"), now: now
        ))
        // A replay of a note that waited hours for the Mac to wake.
        XCTAssertTrue(ContentDedupCache.matches(
            entries: [entry], handle: "+15555550199", text: "Test", attachmentCount: 0,
            sentAt: date("2026-11-16T09:00:00Z"), now: now
        ))
        // A new note: sent after that capture.
        XCTAssertFalse(ContentDedupCache.matches(
            entries: [entry], handle: "+15555550199", text: "Test", attachmentCount: 0,
            sentAt: date("2026-11-17T13:19:00Z"), now: now
        ))
    }

    func testSameWordsKeepOneEntryForEachNote() {
        // "Buy milk" on day 1 and again on day 10 are two notes. A late replay
        // of either one must still be caught, so the second must not replace
        // the first.
        let day1 = date("2026-11-01T15:00:00Z")
        let day10 = date("2026-11-10T15:00:00Z")
        var entries = ContentDedupCache.appendEntry(
            into: [], handle: "+15555550199", text: "Buy milk", attachmentCount: 0,
            sentAt: day1, now: day1.addingTimeInterval(2)
        )
        entries = ContentDedupCache.appendEntry(
            into: entries, handle: "+15555550199", text: "Buy milk", attachmentCount: 0,
            sentAt: day10, now: day10.addingTimeInterval(2)
        )
        XCTAssertEqual(entries.count, 2)
        let later = date("2026-11-12T15:00:00Z")
        for replayOf in [day1, day10] {
            XCTAssertTrue(ContentDedupCache.matches(
                entries: entries, handle: "+15555550199", text: "Buy milk", attachmentCount: 0,
                sentAt: replayOf.addingTimeInterval(1), now: later
            ))
        }
        // A third time, sent now, is a new note.
        XCTAssertFalse(ContentDedupCache.matches(
            entries: entries, handle: "+15555550199", text: "Buy milk", attachmentCount: 0,
            sentAt: later, now: later
        ))
    }

    func testANewNoteDoesNotRemoveAnEntryWithoutASendTime() {
        let old = CaptureHashEntry(
            handleNormalized: "+15555550199", normalizedText: "test", attachmentCount: 0,
            expiresAt: date("2027-02-14T17:12:03Z"), sentAt: nil
        )
        let newSend = date("2026-11-17T13:19:00Z")
        let entries = ContentDedupCache.appendEntry(
            into: [old], handle: "+15555550199", text: "Test", attachmentCount: 0,
            sentAt: newSend, now: newSend.addingTimeInterval(2)
        )
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first, old)
        XCTAssertEqual(entries.last?.sentAt, newSend)
    }

    // MARK: - state.json

    @MainActor
    func testAnEntryFromAnOlderVersionDecodes() throws {
        // state.json written before `sentAt` existed. It must load, or the
        // whole state file is lost.
        let json = """
        {"handleNormalized":"+15555550199","normalizedText":"test","attachmentCount":0,"expiresAt":"2027-02-14T17:12:03Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(CaptureHashEntry.self, from: Data(json.utf8))
        XCTAssertNil(entry.sentAt)
        XCTAssertEqual(entry.normalizedText, "test")
        XCTAssertEqual(entry.expiresAt, date("2027-02-14T17:12:03Z"))
    }

    @MainActor
    func testSendTimeSurvivesASaveAndLoad() throws {
        let entry = CaptureHashEntry(
            handleNormalized: "+15555550199", normalizedText: "test", attachmentCount: 0,
            expiresAt: date("2027-02-15T13:19:02Z"), sentAt: date("2026-11-17T13:19:00Z")
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = try decoder.decode(CaptureHashEntry.self, from: encoder.encode(entry))
        XCTAssertEqual(loaded, entry)
    }
}
