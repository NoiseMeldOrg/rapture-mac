import XCTest
@testable import Rapture

/// Pure-planner tests for `TriageWatcher.plan` — no filesystem, no clock.
final class TriageWatcherPlanTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ name: String, dir: Bool = false, size: Int = 10, mtime: Date? = nil) -> TriageWatcher.Entry {
        TriageWatcher.Entry(name: name, isDirectory: dir, size: size, modifiedAt: mtime)
    }

    /// firstSeen + previousSizes as they'd be after a prior scan of the same entries.
    private func afterPriorScan(of entries: [TriageWatcher.Entry], ago: TimeInterval = 5) -> ([String: Date], [String: Int]) {
        var seen: [String: Date] = [:]
        var sizes: [String: Int] = [:]
        for e in entries where !e.isDirectory && !e.name.hasPrefix(".") && e.name.lowercased().hasSuffix(".txt") {
            seen[e.name] = now.addingTimeInterval(-ago)
            sizes[e.name] = e.size
        }
        return (seen, sizes)
    }

    // MARK: - Selection

    func testSelectsOnlyRootTxtFiles() {
        let entries = [
            entry("note.txt"),
            entry("note.md"),
            entry("Notes", dir: true),
            entry("photo.heic"),
            entry(".DS_Store"),
            entry("draft.txt.tmp"),
            entry("2026-07-06T15-14-42Z Ideas", dir: true)
        ]
        let (seen, sizes) = afterPriorScan(of: entries)
        let plan = TriageWatcher.plan(entries: entries, firstSeen: seen, previousSizes: sizes, now: now)
        XCTAssertEqual(plan.ready, ["note.txt"], "only settled root .txt files are work")
    }

    func testUppercaseExtensionSelected() {
        let entries = [entry("SHOUTY.TXT")]
        let (seen, sizes) = afterPriorScan(of: entries)
        let plan = TriageWatcher.plan(entries: entries, firstSeen: seen, previousSizes: sizes, now: now)
        XCTAssertEqual(plan.ready, ["SHOUTY.TXT"])
    }

    // MARK: - Settle rules

    func testFirstSightingIsNeverReady() {
        let plan = TriageWatcher.plan(entries: [entry("new.txt")], firstSeen: [:], previousSizes: [:], now: now)
        XCTAssertTrue(plan.ready.isEmpty, "a file needs age and a stable size before it's work")
        XCTAssertEqual(plan.newFirstSeen["new.txt"], now)
        XCTAssertEqual(plan.newSizes["new.txt"], 10)
    }

    func testGrowingFileIsNotReady() {
        let entries = [entry("growing.txt", size: 200)]
        let seen = ["growing.txt": now.addingTimeInterval(-10)]
        let sizes = ["growing.txt": 100]  // was smaller last scan
        let plan = TriageWatcher.plan(entries: entries, firstSeen: seen, previousSizes: sizes, now: now)
        XCTAssertTrue(plan.ready.isEmpty)
        XCTAssertEqual(plan.newSizes["growing.txt"], 200, "the new size becomes the stability baseline")
    }

    func testAgedAndStableIsReady() {
        let entries = [entry("stable.txt", size: 100)]
        let seen = ["stable.txt": now.addingTimeInterval(-TriageWatcher.settleAge)]
        let sizes = ["stable.txt": 100]
        let plan = TriageWatcher.plan(entries: entries, firstSeen: seen, previousSizes: sizes, now: now)
        XCTAssertEqual(plan.ready, ["stable.txt"])
    }

    func testZeroByteFileSettlesLikeAnyOther() {
        let entries = [entry("empty.txt", size: 0)]
        let seen = ["empty.txt": now.addingTimeInterval(-10)]
        let sizes = ["empty.txt": 0]
        let plan = TriageWatcher.plan(entries: entries, firstSeen: seen, previousSizes: sizes, now: now)
        XCTAssertEqual(plan.ready, ["empty.txt"], "zero-byte files must not be stuck forever")
    }

    func testVanishedFilesArePrunedFromState() {
        let plan = TriageWatcher.plan(
            entries: [],
            firstSeen: ["gone.txt": now.addingTimeInterval(-100)],
            previousSizes: ["gone.txt": 5],
            now: now
        )
        XCTAssertTrue(plan.newFirstSeen.isEmpty)
        XCTAssertTrue(plan.newSizes.isEmpty)
    }

    // MARK: - Placeholders

    func testICloudTxtPlaceholderIsNudged() {
        let entries = [entry(".2026-07-06T15-14-42Z Ideas.txt.icloud")]
        let plan = TriageWatcher.plan(entries: entries, firstSeen: [:], previousSizes: [:], now: now)
        XCTAssertEqual(plan.placeholdersToNudge, [".2026-07-06T15-14-42Z Ideas.txt.icloud"])
        XCTAssertTrue(plan.ready.isEmpty)
    }

    func testNonTxtPlaceholderIgnored() {
        let entries = [entry(".photo.heic.icloud")]
        let plan = TriageWatcher.plan(entries: entries, firstSeen: [:], previousSizes: [:], now: now)
        XCTAssertTrue(plan.placeholdersToNudge.isEmpty)
    }

    // MARK: - Ordering

    func testReadyOrderedOldestFirstByContractTimestampThenMtime() {
        let entries = [
            entry("2026-07-10T10-00-00Z.txt", size: 5),
            entry("2026-07-08T10-00-00Z Ideas.txt", size: 5),
            entry("freeform.txt", size: 5, mtime: Date(timeIntervalSince1970: 1_700_000_000))  // oldest
        ]
        let (seen, sizes) = afterPriorScan(of: entries)
        let plan = TriageWatcher.plan(entries: entries, firstSeen: seen, previousSizes: sizes, now: now)
        XCTAssertEqual(plan.ready, [
            "freeform.txt",
            "2026-07-08T10-00-00Z Ideas.txt",
            "2026-07-10T10-00-00Z.txt"
        ])
    }
}
