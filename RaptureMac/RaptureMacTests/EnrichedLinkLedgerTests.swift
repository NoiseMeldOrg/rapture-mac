import XCTest
@testable import Rapture

/// The enriched-link dedup ledger's pure helpers: TTL expiry, capacity FIFO,
/// fingerprint refresh, and the relocation remap.
@MainActor
final class EnrichedLinkLedgerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_784_000_000)

    private func entry(_ fp: String, path: String = "Links/Media/A.md", title: String = "A", at date: Date) -> EnrichedLinkEntry {
        EnrichedLinkEntry(fingerprint: fp, artifactRelativePath: path, title: title, fetchedAt: date)
    }

    func testAppendAndLookup() {
        let entries = EnrichedLinkLedger.appendEntry(
            into: [], fingerprint: "yt:abc", artifactRelativePath: "Links/Media/2026-07-13 T.md", title: "T", now: now)
        let hit = EnrichedLinkLedger.entry(in: entries, fingerprint: "yt:abc", now: now)
        XCTAssertEqual(hit?.title, "T")
        XCTAssertEqual(hit?.artifactRelativePath, "Links/Media/2026-07-13 T.md")
        XCTAssertNil(EnrichedLinkLedger.entry(in: entries, fingerprint: "yt:other", now: now))
    }

    func testExpiredEntryIsNotALedgerHit() {
        let old = entry("yt:abc", at: now.addingTimeInterval(-EnrichedLinkLedger.ttl - 1))
        XCTAssertNil(EnrichedLinkLedger.entry(in: [old], fingerprint: "yt:abc", now: now))
    }

    func testAppendPrunesExpiredAndRefreshesFingerprint() {
        let stale = entry("yt:old", at: now.addingTimeInterval(-EnrichedLinkLedger.ttl - 1))
        let existing = entry("yt:abc", path: "Links/Media/Old.md", title: "Old", at: now.addingTimeInterval(-100))
        let entries = EnrichedLinkLedger.appendEntry(
            into: [stale, existing], fingerprint: "yt:abc", artifactRelativePath: "Links/Media/New.md", title: "New", now: now)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].title, "New")
    }

    func testCapacityEvictsOldestFirst() {
        var entries: [EnrichedLinkEntry] = []
        for i in 0..<(EnrichedLinkLedger.capacity + 10) {
            entries = EnrichedLinkLedger.appendEntry(
                into: entries, fingerprint: "yt:\(i)", artifactRelativePath: "p\(i)", title: "t\(i)",
                now: now.addingTimeInterval(TimeInterval(i)))
        }
        XCTAssertEqual(entries.count, EnrichedLinkLedger.capacity)
        XCTAssertEqual(entries.first?.fingerprint, "yt:10")
    }

    func testRemapRewritesOnlyMatchingPaths() {
        let a = entry("yt:a", path: "Links/Media/A.md", at: now)
        let b = entry("yt:b", path: "Links/Media/B.md", at: now)
        let remapped = EnrichedLinkLedger.remapped([a, b], renamedNotes: ["Links/Media/A.md": "Links/Media/A-1.md"])
        XCTAssertEqual(remapped[0].artifactRelativePath, "Links/Media/A-1.md")
        XCTAssertEqual(remapped[0].fingerprint, "yt:a")
        XCTAssertEqual(remapped[1], b)
    }

    func testRecordPersistsThroughStateStore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("enriched-ledger-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(directory: dir)
        let ledger = EnrichedLinkLedger(stateStore: store)

        ledger.record(fingerprint: "yt:abc", artifactRelativePath: "Links/Media/T.md", title: "T")
        XCTAssertEqual(ledger.entry(fingerprint: "yt:abc")?.title, "T")

        let reloaded = StateStore(directory: dir)
        XCTAssertEqual(EnrichedLinkLedger(stateStore: reloaded).entry(fingerprint: "yt:abc")?.title, "T")
    }

    // MARK: - Video flag (social posts)

    func testVideoFlagIsRecordedOnlyWhenTrue() {
        let video = EnrichedLinkLedger.appendEntry(
            into: [], fingerprint: "url:https://www.facebook.com/reel/1", artifactRelativePath: "Links/Media/V.md",
            title: "V", isVideo: true, now: now)
        XCTAssertEqual(video.first?.isVideo, true)

        let plain = EnrichedLinkLedger.appendEntry(
            into: [], fingerprint: "yt:abc", artifactRelativePath: "Links/Media/T.md", title: "T", now: now)
        XCTAssertNil(plain.first?.isVideo, "YouTube and plain articles never carry the flag")

        let notVideo = EnrichedLinkLedger.appendEntry(
            into: [], fingerprint: "url:https://www.facebook.com/somepage/posts/1", artifactRelativePath: "Links/Media/P.md",
            title: "P", isVideo: false, now: now)
        XCTAssertNil(notVideo.first?.isVideo)
    }

    func testRefreshReplacesTheVideoFlag() {
        let first = EnrichedLinkLedger.appendEntry(
            into: [], fingerprint: "url:https://x.com/a/status/1", artifactRelativePath: "Links/Media/A.md",
            title: "A", isVideo: true, now: now)
        let second = EnrichedLinkLedger.appendEntry(
            into: first, fingerprint: "url:https://x.com/a/status/1", artifactRelativePath: "Links/Media/A2.md",
            title: "A", isVideo: false, now: now)
        XCTAssertEqual(second.count, 1)
        XCTAssertNil(second.first?.isVideo)
    }

    func testRemapKeepsTheVideoFlag() {
        let video = EnrichedLinkEntry(
            fingerprint: "url:https://www.facebook.com/reel/1", artifactRelativePath: "Links/Media/V.md",
            title: "V", fetchedAt: now, isVideo: true)
        let moved = EnrichedLinkLedger.remapped([video], renamedNotes: ["Links/Media/V.md": "Links/Media/V-1.md"])
        XCTAssertEqual(moved.first?.artifactRelativePath, "Links/Media/V-1.md")
        XCTAssertEqual(moved.first?.isVideo, true)
    }
}
