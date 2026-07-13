import XCTest
@testable import Rapture

@MainActor
final class DestinationMonitorTests: XCTestCase {

    private let fm = FileManager.default
    private var root: URL!
    private var output: URL!
    private var support: URL!
    private var appState: AppState!
    private var spool: SpoolStore!
    private var ledger: SpoolFiledLedger!

    /// Availability the tests flip between ticks.
    private final class VolumeSwitch: @unchecked Sendable {
        var mounted = false
    }
    private var volume: VolumeSwitch!
    private var flippableGuard: DestinationGuard!

    /// Test clock, boxed so the monitor's Sendable clock closure can read it.
    private final class ClockBox: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_750_000_000)
    }
    private let clockBox = ClockBox()
    private var now: Date {
        get { clockBox.now }
        set { clockBox.now = newValue }
    }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("dest-monitor-\(UUID().uuidString)", isDirectory: true)
        // A /Volumes-shaped destination: with the flippable guard unmounted this
        // classifies volumeAbsent (not folderMissing). Never touched on disk —
        // the fake flusher writes nothing.
        output = URL(fileURLWithPath: "/Volumes/RaptureMonitor-\(UUID().uuidString)/Notes")
        support = root.appendingPathComponent("Support", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        volume = VolumeSwitch()
        let volume = self.volume!
        flippableGuard = DestinationGuard(
            directoryExists: { _ in volume.mounted },
            isVolumeRoot: { _ in volume.mounted }
        )

        appState = AppState(supportDirectory: support)
        appState.settings.update {
            $0.outputFolder = output
            $0.paused = false
            $0.triageMode = .full
        }
        spool = SpoolStore(directory: root.appendingPathComponent("Spool", isDirectory: true), stateStore: appState.state)
        ledger = SpoolFiledLedger(stateStore: appState.state)
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
    }

    private final class FakeFlusher: SpoolFiling, @unchecked Sendable {
        enum Behavior {
            case succeed
            case failAll(String)
            case failItem(named: String, reason: String)
            case unavailableFrom(index: Int)
        }
        var behavior: Behavior = .succeed
        private(set) var filedNames: [String] = []

        func file(_ item: SpoolItem, to folder: URL, mode: TriageMode) async -> WriteResult {
            switch behavior {
            case .succeed:
                break
            case .failAll(let reason):
                return WriteResult(outcome: .failure(reason: reason), failedAttachments: [])
            case .failItem(let name, let reason):
                if item.name == name {
                    return WriteResult(outcome: .failure(reason: reason), failedAttachments: [])
                }
            case .unavailableFrom(let index):
                if filedNames.count >= index {
                    return WriteResult(outcome: .unavailable, failedAttachments: [])
                }
            }
            filedNames.append(item.name)
            return WriteResult(
                outcome: .success(folder.appendingPathComponent("Notes/\(item.name).md")),
                failedAttachments: []
            )
        }
    }

    private func makeMonitor(flusher: FakeFlusher = FakeFlusher()) -> (DestinationMonitor, FakeFlusher) {
        let clockBox = self.clockBox
        let monitor = DestinationMonitor(
            appState: appState,
            spool: spool,
            flusher: flusher,
            ledger: ledger,
            destinationGuard: flippableGuard,
            clock: { clockBox.now }
        )
        return (monitor, flusher)
    }

    @discardableResult
    private func enqueue(_ text: String) async throws -> SpoolItem {
        try await spool.add(text: text, capturedAt: now, source: .raptureMac)
    }

    // MARK: - Status

    func testOfflineTickSetsStatusAndCount() async throws {
        volume.mounted = false
        try await enqueue("a")
        try await enqueue("b")
        appState.relayPendingOffline = 3

        let (monitor, flusher) = makeMonitor()
        await monitor.tick()

        XCTAssertTrue(appState.destinationOffline)
        XCTAssertEqual(appState.queuedCaptureCount, 5)
        XCTAssertTrue(flusher.filedNames.isEmpty, "no flush while offline")
    }

    func testOnlineEmptySpoolClearsStatus() async {
        volume.mounted = true
        appState.destinationOffline = true
        let (monitor, _) = makeMonitor()
        await monitor.tick()
        XCTAssertFalse(appState.destinationOffline)
        XCTAssertEqual(appState.queuedCaptureCount, 0)
    }

    // MARK: - Flush

    func testRemountFlushesInSeqOrderAndEmptiesSpool() async throws {
        volume.mounted = false
        let first = try await enqueue("first")
        let second = try await enqueue("second")
        let third = try await enqueue("third")

        volume.mounted = true
        let (monitor, flusher) = makeMonitor()
        await monitor.tick()

        XCTAssertEqual(flusher.filedNames, [first.name, second.name, third.name])
        XCTAssertTrue(spool.isEmpty)
        XCTAssertEqual(appState.queuedCaptureCount, 0)
        XCTAssertEqual(appState.state.state.todayCount, 0, "flush never re-counts")
        XCTAssertTrue(ledger.contains(itemName: first.name))
    }

    func testMidFlushUnavailabilityPreservesRemainderInOrder() async throws {
        volume.mounted = false
        let first = try await enqueue("first")
        _ = try await enqueue("second")
        let third = try await enqueue("third")

        volume.mounted = true
        let flusher = FakeFlusher()
        flusher.behavior = .unavailableFrom(index: 2)
        let (monitor, _) = makeMonitor(flusher: flusher)
        await monitor.tick()

        XCTAssertEqual(flusher.filedNames.count, 2)
        let remaining = spool.items()
        XCTAssertEqual(remaining.map(\.name), [third.name])
        XCTAssertTrue(ledger.contains(itemName: first.name))
    }

    func testHeadFailureBlocksQueueAndBacksOff() async throws {
        volume.mounted = false
        let first = try await enqueue("head")
        _ = try await enqueue("behind")

        volume.mounted = true
        let flusher = FakeFlusher()
        flusher.behavior = .failItem(named: first.name, reason: "destination full")
        let (monitor, _) = makeMonitor(flusher: flusher)

        await monitor.tick()
        XCTAssertEqual(flusher.filedNames, [], "FIFO-strict: nothing skips a failing head")
        XCTAssertEqual(spool.count, 2)
        XCTAssertEqual(appState.lastError, "Couldn't file queued capture: destination full")

        // Within the backoff window nothing retries…
        flusher.behavior = .succeed
        now = now.addingTimeInterval(30)
        await monitor.tick()
        XCTAssertEqual(flusher.filedNames, [])

        // …after it, the queue drains in order.
        now = now.addingTimeInterval(31)
        await monitor.tick()
        XCTAssertEqual(flusher.filedNames.count, 2)
        XCTAssertTrue(spool.isEmpty)
    }

    func testLedgerHitDrainsWithoutRefiling() async throws {
        volume.mounted = false
        let item = try await enqueue("already filed before crash")
        ledger.record(itemName: item.name)

        volume.mounted = true
        let (monitor, flusher) = makeMonitor()
        await monitor.tick()

        XCTAssertEqual(flusher.filedNames, [], "crash resume is delete-only")
        XCTAssertTrue(spool.isEmpty)
    }

    func testPausedAndRelocatingDeferFlush() async throws {
        volume.mounted = false
        try await enqueue("queued")
        volume.mounted = true

        appState.settings.update { $0.paused = true }
        let (monitor, flusher) = makeMonitor()
        await monitor.tick()
        XCTAssertEqual(flusher.filedNames, [])

        appState.settings.update { $0.paused = false }
        appState.isRelocating = true
        await monitor.tick()
        XCTAssertEqual(flusher.filedNames, [])

        appState.isRelocating = false
        await monitor.tick()
        XCTAssertEqual(flusher.filedNames.count, 1)
    }
}
