import XCTest
@testable import Rapture

/// Offline-destination behavior of the three capture processors: iMessage
/// captures spool, relay files defer in place, triage returns before any mkdir.
@MainActor
final class DestinationOfflineTests: XCTestCase {

    private let fm = FileManager.default
    private var root: URL!
    private var output: URL!
    private var support: URL!
    private var spoolDir: URL!
    /// A destination on a volume that is genuinely not mounted — the real
    /// `DestinationGuard` probes classify it `volumeAbsent`.
    private var phantomOutput: URL!

    private let availableGuard = DestinationGuard(directoryExists: { _ in true }, isVolumeRoot: { _ in true })

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("dest-offline-\(UUID().uuidString)", isDirectory: true)
        output = root.appendingPathComponent("Notes", isDirectory: true)
        support = root.appendingPathComponent("Support", isDirectory: true)
        spoolDir = root.appendingPathComponent("Spool", isDirectory: true)
        phantomOutput = URL(fileURLWithPath: "/Volumes/RaptureOffline-\(UUID().uuidString)/Notes")
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
    }

    // MARK: - Harness

    private final class FakeSender: AppleScriptSending, @unchecked Sendable {
        var sent: [(text: String, chatGuid: String)] = []
        func send(text: String, toChatGuid chatGuid: String) async throws {
            sent.append((text, chatGuid))
        }
    }

    private final class FakeNotifications: NotificationDispatching, @unchecked Sendable {
        func send(title: String, body: String) async {}
    }

    private final class FakeWriter: FileWriting, @unchecked Sendable {
        var result = WriteResult(outcome: .success(URL(fileURLWithPath: "/dev/null/x.md")), failedAttachments: [])
        var calls = 0
        var onWrite: (@Sendable () -> Void)?
        func write(_ captured: CapturedMessage, to folder: URL, mode: TriageMode) async -> WriteResult {
            calls += 1
            onWrite?()
            return result
        }
    }

    private func makeAppState() -> AppState {
        let appState = AppState(supportDirectory: support)
        appState.settings.update {
            $0.outputFolder = output
            $0.paused = false
            $0.relayEnabled = true
            $0.triageMode = .full
            $0.replyMode = .all
        }
        // Skip the one-shot automation pre-prompt in tests.
        appState.state.update { $0.automationPrePromptShown = true }
        return appState
    }

    private func makeBatchProcessor(
        appState: AppState,
        writer: FileWriting,
        sender: FakeSender,
        destinationGuard: DestinationGuard
    ) -> (BatchProcessor, SpoolStore) {
        let spool = SpoolStore(directory: spoolDir, stateStore: appState.state)
        let replier = Replier(
            sender: sender,
            echoGuard: EchoGuard(stateStore: appState.state),
            notifications: FakeNotifications(),
            stateStore: appState.state,
            appState: appState,
            prePromptHandler: { true }
        )
        let processor = BatchProcessor(
            appState: appState,
            writer: writer,
            replier: replier,
            echoGuard: EchoGuard(stateStore: appState.state),
            contentDedupCache: ContentDedupCache(stateStore: appState.state),
            spool: spool,
            destinationGuard: destinationGuard,
            selfHandlesProvider: { ["+15555550100"] },
            selfChatGuidProvider: { nil },
            advanceWatermark: { [weak appState] rowid in
                appState?.state.update { $0.chatDbWatermark = max($0.chatDbWatermark, rowid) }
            }
        )
        return (processor, spool)
    }

    private func event(rowid: Int64, text: String) -> MessageEvent {
        MessageEvent(
            rowid: rowid,
            guid: "guid-\(rowid)",
            text: text,
            attributedBody: nil,
            dateAppleNs: rowid * 1_000_000_000,
            isFromMe: false,
            cacheHasAttachments: false,
            service: "iMessage",
            handleId: "+15555550100",
            chatGuid: "iMessage;-;chat-self",
            chatStyle: 45,
            attachments: []
        )
    }

    // MARK: - BatchProcessor spools

    func testVolumeAbsentSpoolsAdvancesWatermarkCountsAndRepliesQueued() async throws {
        let appState = makeAppState()
        appState.settings.update { $0.outputFolder = phantomOutput }
        let writer = FakeWriter()
        let sender = FakeSender()
        let (processor, spool) = makeBatchProcessor(
            appState: appState, writer: writer, sender: sender, destinationGuard: DestinationGuard()
        )

        let outcome = await processor.process(batch: [event(rowid: 7, text: "note while unplugged")])

        XCTAssertEqual(outcome.successCount, 1)
        XCTAssertEqual(writer.calls, 0, "no write may be attempted toward an absent volume")
        XCTAssertEqual(spool.count, 1)
        XCTAssertEqual(appState.state.state.chatDbWatermark, 7, "spool is durable — watermark advances")
        XCTAssertEqual(appState.state.state.todayCount, 1, "counts at capture time")
        XCTAssertEqual(sender.sent.map(\.text), ["✅ Queued — destination offline"])

        let item = try XCTUnwrap(spool.items().first)
        XCTAssertEqual(item.metadata.source, .raptureMac)
        let text = try String(contentsOf: item.captureTextURL, encoding: .utf8)
        XCTAssertEqual(text, "note while unplugged")
    }

    func testNonEmptySpoolForcesSpoolingEvenWhenAvailable() async throws {
        // FIFO rule: after remount, a live batch must not write ahead of queued
        // captures — it spools behind them until the monitor drains the queue.
        let appState = makeAppState()
        let writer = FakeWriter()
        let sender = FakeSender()
        let (processor, spool) = makeBatchProcessor(
            appState: appState, writer: writer, sender: sender, destinationGuard: availableGuard
        )
        try await spool.add(text: "older, queued", capturedAt: Date(), source: .raptureMac)

        _ = await processor.process(batch: [event(rowid: 8, text: "newer, live")])

        XCTAssertEqual(writer.calls, 0)
        XCTAssertEqual(spool.count, 2)
        let texts = try spool.items().map { try String(contentsOf: $0.captureTextURL, encoding: .utf8) }
        XCTAssertEqual(texts, ["older, queued", "newer, live"])
    }

    func testWriteFailureRacedByUnplugSpoolsInsteadOfErroring() async throws {
        // The guard said available, the write failed, and by then the guard says
        // absent: the failure WAS the unplug — spool, don't surface an error.
        let appState = makeAppState()
        appState.settings.update { $0.outputFolder = phantomOutput }
        let writer = FakeWriter()
        let sender = FakeSender()

        // Mounted for the pre-write check; the write "fails" (FakeWriter), and by
        // the post-failure re-check the volume is gone.
        final class VolumeSwitch: @unchecked Sendable { var mounted = true }
        let volume = VolumeSwitch()
        writer.onWrite = { volume.mounted = false }
        writer.result = WriteResult(outcome: .failure(reason: "vanished mid-write"), failedAttachments: [])
        let flippingGuard = DestinationGuard(
            directoryExists: { _ in volume.mounted },
            isVolumeRoot: { _ in volume.mounted }
        )
        let (processor, spool) = makeBatchProcessor(
            appState: appState, writer: writer, sender: sender, destinationGuard: flippingGuard
        )

        let outcome = await processor.process(batch: [event(rowid: 9, text: "raced")])

        XCTAssertEqual(outcome.successCount, 1)
        XCTAssertEqual(outcome.failureCount, 0)
        XCTAssertEqual(writer.calls, 1)
        XCTAssertEqual(spool.count, 1)
        XCTAssertNil(appState.lastError)
        XCTAssertEqual(sender.sent.map(\.text), ["✅ Queued — destination offline"])
    }

    func testWriteFailureWithVolumePresentKeepsErrorBehavior() async throws {
        let appState = makeAppState()
        let writer = FakeWriter()
        writer.result = WriteResult(outcome: .failure(reason: "disk full"), failedAttachments: [])
        let sender = FakeSender()
        let (processor, spool) = makeBatchProcessor(
            appState: appState, writer: writer, sender: sender, destinationGuard: availableGuard
        )

        let outcome = await processor.process(batch: [event(rowid: 10, text: "fails")])

        XCTAssertEqual(outcome.failureCount, 1)
        XCTAssertEqual(spool.count, 0, "non-volume failures never spool")
        XCTAssertEqual(appState.lastError, "disk full")
        XCTAssertEqual(appState.state.state.chatDbWatermark, 0, "failed row replays")
        XCTAssertEqual(sender.sent.map(\.text), ["✗ disk full"])
    }

    func testUnavailableWriterResultSpools() async throws {
        // Defense in depth: FileWriter's internal guard fired even though the
        // processor's pre-check said available.
        let appState = makeAppState()
        let writer = FakeWriter()
        writer.result = WriteResult(outcome: .unavailable, failedAttachments: [])
        let sender = FakeSender()
        let (processor, spool) = makeBatchProcessor(
            appState: appState, writer: writer, sender: sender, destinationGuard: availableGuard
        )

        let outcome = await processor.process(batch: [event(rowid: 11, text: "guarded away")])

        XCTAssertEqual(outcome.successCount, 1)
        XCTAssertEqual(spool.count, 1)
        XCTAssertNil(appState.lastError)
    }

    func testSpooledCaptureTracksContentDedup() async throws {
        // An iCloud cross-device replay of a spooled capture must be suppressed
        // exactly as if it had been written live.
        let appState = makeAppState()
        appState.settings.update { $0.outputFolder = phantomOutput }
        let writer = FakeWriter()
        let sender = FakeSender()
        let (processor, spool) = makeBatchProcessor(
            appState: appState, writer: writer, sender: sender, destinationGuard: DestinationGuard()
        )

        _ = await processor.process(batch: [event(rowid: 12, text: "same content")])
        // Different rowid + guid, identical content — the content dedup must catch it.
        var replay = event(rowid: 13, text: "same content")
        replay = MessageEvent(
            rowid: 13, guid: "guid-different", text: "same content", attributedBody: nil,
            dateAppleNs: replay.dateAppleNs, isFromMe: false, cacheHasAttachments: false,
            service: "iMessage", handleId: "+15555550100", chatGuid: "iMessage;-;chat-self",
            chatStyle: 45, attachments: []
        )
        let outcome = await processor.process(batch: [replay])

        XCTAssertEqual(outcome.droppedCount, 1)
        XCTAssertEqual(spool.count, 1, "replay must not spool a duplicate")
    }

    // MARK: - RelayProcessor defers in place

    func testRelayDefersQuietlyWhenVolumeAbsent() async throws {
        let appState = makeAppState()
        appState.settings.update { $0.outputFolder = phantomOutput }
        let relayDir = root.appendingPathComponent("Relay", isDirectory: true)
        try fm.createDirectory(at: relayDir, withIntermediateDirectories: true)
        let txtURL = relayDir.appendingPathComponent("2026-07-13T14-00-00Z Idea.txt")
        try "body".write(to: txtURL, atomically: true, encoding: .utf8)

        final class CountingFiler: RelayFiling, @unchecked Sendable {
            var calls = 0
            func file(_ candidate: RelayCandidate, to folder: URL, mode: TriageMode) async -> WriteResult {
                calls += 1
                return WriteResult(outcome: .success(URL(fileURLWithPath: "/dev/null")), failedAttachments: [])
            }
            func fileOrphanAudio(at url: URL, to folder: URL, preferredDirectory: URL?) async -> WriteResult {
                WriteResult(outcome: .success(URL(fileURLWithPath: "/dev/null")), failedAttachments: [])
            }
        }
        let filer = CountingFiler()
        let processor = RelayProcessor(
            appState: appState,
            filer: filer,
            ledger: RelayFiledLedger(stateStore: appState.state),
            triageLedger: TriageLedger(stateStore: appState.state),
            destinationGuard: DestinationGuard()
        )

        let candidate = RelayCandidate(
            txtURL: txtURL, audioURL: nil,
            relayFilename: txtURL.lastPathComponent,
            baseName: "2026-07-13T14-00-00Z Idea"
        )
        await processor.process(batch: RelayScanBatch(candidates: [candidate], orphanAudio: []))

        XCTAssertEqual(filer.calls, 0)
        XCTAssertNil(appState.relayLastError, "offline is a status, not an error")
        XCTAssertNil(appState.lastError)
        XCTAssertEqual(appState.relayPendingOffline, 1)
        XCTAssertTrue(fm.fileExists(atPath: txtURL.path), "relay copy stays put")

        // Volume returns: pending count clears on the next processed batch.
        let onlineProcessor = RelayProcessor(
            appState: appState,
            filer: filer,
            ledger: RelayFiledLedger(stateStore: appState.state),
            triageLedger: TriageLedger(stateStore: appState.state),
            destinationGuard: availableGuard
        )
        await onlineProcessor.process(batch: RelayScanBatch(candidates: [], orphanAudio: []))
        XCTAssertEqual(appState.relayPendingOffline, 0)
    }

    // MARK: - TriageProcessor guard

    func testTriageReturnsBeforeAnyMkdirWhenVolumeAbsent() async throws {
        let appState = makeAppState()
        // Point the destination at a phantom /Volumes path; a shadow mkdir would
        // create it on the boot volume.
        let phantom = URL(fileURLWithPath: "/Volumes/RaptureTriageTest-\(UUID().uuidString)/Notes")
        appState.settings.update { $0.outputFolder = phantom }

        let processor = TriageProcessor(
            appState: appState,
            ledger: TriageLedger(stateStore: appState.state)
        )
        let batch = TriageScanBatch(candidates: [TriageCandidate(filename: "2026-07-13T14-00-00Z.txt")])
        await processor.process(batch: batch)

        XCTAssertFalse(fm.fileExists(atPath: phantom.deletingLastPathComponent().path),
                       "no shadow folder may appear under /Volumes")
        XCTAssertNil(appState.triageLastError)
    }
}
