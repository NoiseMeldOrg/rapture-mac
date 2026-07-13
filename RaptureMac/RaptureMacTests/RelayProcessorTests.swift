import XCTest
@testable import Rapture

/// Drives the relay filing pipeline end-to-end against temp relay/output dirs.
///
/// `AppState` gets a temp `supportDirectory`, so settings.json/state.json are
/// fully isolated from the dev machine's live container — tests neither read
/// real relay-ledger state (milestone 4 dogfood finding: real filings broke
/// ledger-emptiness assertions) nor write to it.
@MainActor
final class RelayProcessorTests: XCTestCase {

    private let fm = FileManager.default
    private var root: URL!
    private var relay: URL!
    private var output: URL!
    private var support: URL!

    private let baseName = "2026-07-06T15-14-42Z Grocery Ideas"
    private var txtName: String { baseName + ".txt" }
    private var m4aName: String { baseName + ".m4a" }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("relay-proc-\(UUID().uuidString)", isDirectory: true)
        relay = root.appendingPathComponent("Relay", isDirectory: true)
        output = root.appendingPathComponent("Notes", isDirectory: true)
        support = root.appendingPathComponent("Support", isDirectory: true)
        try fm.createDirectory(at: relay, withIntermediateDirectories: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
    }

    // MARK: - Harness

    @MainActor
    private final class FakeFiler: RelayFiling {
        var result = WriteResult(outcome: .success(URL(fileURLWithPath: "/dev/null")), failedAttachments: [])
        var orphanResult = WriteResult(outcome: .success(URL(fileURLWithPath: "/dev/null")), failedAttachments: [])
        private(set) var fileCalls: [RelayCandidate] = []
        private(set) var orphanCalls: [URL] = []

        func file(_ candidate: RelayCandidate, to folder: URL, mode: TriageMode) async -> WriteResult {
            fileCalls.append(candidate)
            return result
        }

        func fileOrphanAudio(at url: URL, to folder: URL, preferredDirectory: URL?) async -> WriteResult {
            orphanCalls.append(url)
            preferredDirectories.append(preferredDirectory)
            return orphanResult
        }

        private(set) var preferredDirectories: [URL?] = []
    }

    /// Existing behavior tests pin the pre-triage (.raw) semantics; triage-specific
    /// processor behavior is covered in `RelayProcessorTriageTests`.
    private func makeAppState(triageMode: TriageMode = .raw) -> AppState {
        let appState = AppState(supportDirectory: support)
        appState.settings.update {
            $0.outputFolder = output
            $0.paused = false
            $0.relayEnabled = true
            $0.triageMode = triageMode
        }
        return appState
    }

    private func makeProcessor(
        appState: AppState,
        filer: any RelayFiling,
        now: Date = Date()
    ) -> RelayProcessor {
        RelayProcessor(
            appState: appState,
            filer: filer,
            ledger: RelayFiledLedger(stateStore: appState.state),
            triageLedger: TriageLedger(stateStore: appState.state),
            clock: { now }
        )
    }

    @discardableResult
    private func writeRelayTxt(_ body: String = "# T\n\nbody") throws -> URL {
        let url = relay.appendingPathComponent(txtName)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    private func writeRelayAudio() throws -> URL {
        let url = relay.appendingPathComponent(m4aName)
        try Data([0x01]).write(to: url)
        return url
    }

    private func candidate(txtURL: URL, audioURL: URL? = nil) -> RelayCandidate {
        RelayCandidate(txtURL: txtURL, audioURL: audioURL, relayFilename: txtName, baseName: baseName)
    }

    // MARK: - Happy path

    func testFilesRecordsLedgerThenDeletesRelayCopies() async throws {
        let appState = makeAppState()
        let processor = makeProcessor(appState: appState, filer: RelayFiler())
        let txtURL = try writeRelayTxt("# T\n\nbody")
        let audioURL = try writeRelayAudio()
        let todayBefore = appState.state.state.displayedTodayCount(at: Date())

        await processor.process(batch: RelayScanBatch(
            candidates: [candidate(txtURL: txtURL, audioURL: audioURL)],
            orphanAudio: []
        ))

        XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent(txtName).path))
        XCTAssertFalse(fm.fileExists(atPath: txtURL.path), "relay txt is removed after filing")
        XCTAssertFalse(fm.fileExists(atPath: audioURL.path), "relay audio is removed after filing")
        XCTAssertTrue(appState.state.state.relayFiledRecords.contains { $0.relayFilename == txtName })
        XCTAssertTrue(appState.state.state.relayFiledRecords.contains { $0.relayFilename == m4aName })
        XCTAssertEqual(appState.state.state.displayedTodayCount(at: Date()), todayBefore + 1,
                       "relay arrivals feed the same today count as iMessage captures")
        XCTAssertNil(appState.relayLastError)
    }

    func testLedgerHitDeletesRelayCopyWithoutRefiling() async throws {
        let appState = makeAppState()
        let fake = FakeFiler()
        let processor = makeProcessor(appState: appState, filer: fake)
        let ledger = RelayFiledLedger(stateStore: appState.state)
        ledger.record(relayFilename: txtName)
        let txtURL = try writeRelayTxt()

        await processor.process(batch: RelayScanBatch(candidates: [candidate(txtURL: txtURL)], orphanAudio: []))

        XCTAssertTrue(fake.fileCalls.isEmpty, "an already-filed name must never re-file")
        XCTAssertFalse(fm.fileExists(atPath: txtURL.path), "the relay copy still drains")
    }

    // MARK: - Deferral

    func testPausedDefersWithoutFilingOrDeleting() async throws {
        let appState = makeAppState()
        appState.settings.update { $0.paused = true }
        let fake = FakeFiler()
        let processor = makeProcessor(appState: appState, filer: fake)
        let txtURL = try writeRelayTxt()

        await processor.process(batch: RelayScanBatch(candidates: [candidate(txtURL: txtURL)], orphanAudio: []))

        XCTAssertTrue(fake.fileCalls.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: txtURL.path), "paused must leave the relay untouched")
    }

    func testRelocatingDefersLikePaused() async throws {
        let appState = makeAppState()
        appState.isRelocating = true
        let fake = FakeFiler()
        let processor = makeProcessor(appState: appState, filer: fake)
        let txtURL = try writeRelayTxt()

        await processor.process(batch: RelayScanBatch(candidates: [candidate(txtURL: txtURL)], orphanAudio: []))

        XCTAssertTrue(fake.fileCalls.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: txtURL.path))
    }

    func testMissingOutputFolderReportsError() async throws {
        let appState = makeAppState()
        appState.settings.update { $0.outputFolder = nil }
        let fake = FakeFiler()
        let processor = makeProcessor(appState: appState, filer: fake)
        let txtURL = try writeRelayTxt()

        await processor.process(batch: RelayScanBatch(candidates: [candidate(txtURL: txtURL)], orphanAudio: []))

        XCTAssertTrue(fake.fileCalls.isEmpty)
        XCTAssertNotNil(appState.relayLastError)
        XCTAssertTrue(fm.fileExists(atPath: txtURL.path))
    }

    // MARK: - Failures and backoff

    func testWriteFailureLeavesRelayCopySetsErrorAndBacksOff() async throws {
        let appState = makeAppState()
        let fake = FakeFiler()
        fake.result = WriteResult(outcome: .failure(reason: "disk full"), failedAttachments: [])
        let processor = makeProcessor(appState: appState, filer: fake)
        let txtURL = try writeRelayTxt()
        let batch = RelayScanBatch(candidates: [candidate(txtURL: txtURL)], orphanAudio: [])

        await processor.process(batch: batch)
        await processor.process(batch: batch) // same tick: inside the backoff window

        XCTAssertEqual(fake.fileCalls.count, 1, "a failed name must not retry every scan")
        XCTAssertEqual(appState.relayLastError, "disk full")
        XCTAssertTrue(fm.fileExists(atPath: txtURL.path), "never delete what wasn't filed")
        XCTAssertTrue(appState.state.state.relayFiledRecords.isEmpty)
    }

    func testShouldAttemptPureBackoffWindows() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(RelayProcessor.shouldAttempt(name: "a.txt", lastFailureAt: [:], now: now))
        XCTAssertFalse(RelayProcessor.shouldAttempt(
            name: "a.txt",
            lastFailureAt: ["a.txt": now.addingTimeInterval(-RelayProcessor.failureRetryBackoff + 1)],
            now: now
        ))
        XCTAssertTrue(RelayProcessor.shouldAttempt(
            name: "a.txt",
            lastFailureAt: ["a.txt": now.addingTimeInterval(-RelayProcessor.failureRetryBackoff)],
            now: now
        ))
    }

    func testFailedAudioCopyDeletesTxtButLeavesM4aForOrphanRecovery() async throws {
        let appState = makeAppState()
        let txtURL = try writeRelayTxt()
        let audioURL = try writeRelayAudio()
        let fake = FakeFiler()
        fake.result = WriteResult(
            outcome: .success(output.appendingPathComponent(txtName)),
            failedAttachments: [audioURL.path]
        )
        let processor = makeProcessor(appState: appState, filer: fake)

        await processor.process(batch: RelayScanBatch(
            candidates: [candidate(txtURL: txtURL, audioURL: audioURL)],
            orphanAudio: []
        ))

        XCTAssertFalse(fm.fileExists(atPath: txtURL.path), "the note filed, so its relay copy drains")
        XCTAssertTrue(fm.fileExists(atPath: audioURL.path), "uncopied audio stays for the orphan path")
        XCTAssertTrue(appState.state.state.relayFiledRecords.contains { $0.relayFilename == txtName })
        XCTAssertFalse(appState.state.state.relayFiledRecords.contains { $0.relayFilename == m4aName },
                       "audio that never copied must not be marked as filed")
        XCTAssertNotNil(appState.relayLastError)
    }

    func testOversizedTxtReportedOnceAndNeverDeleted() async throws {
        let appState = makeAppState()
        let fake = FakeFiler()
        let processor = makeProcessor(appState: appState, filer: fake)
        let url = relay.appendingPathComponent(txtName)
        let oversized = Data(count: RelayProcessor.maxTxtBytes + 1)
        try oversized.write(to: url)
        let batch = RelayScanBatch(candidates: [candidate(txtURL: url)], orphanAudio: [])

        await processor.process(batch: batch)
        XCTAssertNotNil(appState.relayLastError)
        XCTAssertTrue(fake.fileCalls.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: url.path))

        // Clear the surfaced error; a second scan must not re-report the same file.
        appState.relayLastError = nil
        await processor.process(batch: batch)
        XCTAssertNil(appState.relayLastError, "an oversized file is reported once, not every scan")
    }

    // MARK: - Orphan audio

    func testOrphanAudioFilesWithoutIncrementingTodayCount() async throws {
        let appState = makeAppState()
        let processor = makeProcessor(appState: appState, filer: RelayFiler())
        let audioURL = try writeRelayAudio()
        let todayBefore = appState.state.state.displayedTodayCount(at: Date())

        await processor.process(batch: RelayScanBatch(candidates: [], orphanAudio: [audioURL]))

        let filed = output.appendingPathComponent(baseName, isDirectory: true).appendingPathComponent(m4aName)
        XCTAssertTrue(fm.fileExists(atPath: filed.path))
        XCTAssertFalse(fm.fileExists(atPath: audioURL.path))
        XCTAssertTrue(appState.state.state.relayFiledRecords.contains { $0.relayFilename == m4aName })
        XCTAssertEqual(appState.state.state.displayedTodayCount(at: Date()), todayBefore,
                       "the today count counts notes; the note counted when its txt filed")
    }

    func testOrphanAudioLedgerHitDrainsWithoutRefiling() async throws {
        let appState = makeAppState()
        let fake = FakeFiler()
        let processor = makeProcessor(appState: appState, filer: fake)
        RelayFiledLedger(stateStore: appState.state).record(relayFilename: m4aName)
        let audioURL = try writeRelayAudio()

        await processor.process(batch: RelayScanBatch(candidates: [], orphanAudio: [audioURL]))

        XCTAssertTrue(fake.orphanCalls.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: audioURL.path))
    }
}
