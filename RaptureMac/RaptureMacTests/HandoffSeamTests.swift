import XCTest
@testable import Rapture

/// The four filing seams each fire the handoff exactly once per freshly-filed
/// capture — and never on spool-enqueue, failures, or ledger-hit resume paths.
/// This is the M2-log invariant: a spooled "remind me…" hands off at flush, not
/// at capture, so it fires neither late-AND-at-capture (twice) nor not at all.
@MainActor
final class HandoffSeamTests: XCTestCase {

    private let fm = FileManager.default
    private var root: URL!
    private var output: URL!
    private var support: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("handoff-seam-\(UUID().uuidString)", isDirectory: true)
        output = root.appendingPathComponent("Notes", isDirectory: true)
        support = root.appendingPathComponent("Support", isDirectory: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
    }

    // MARK: - Harness

    @MainActor
    private final class SpyHandoff: HandoffProcessing {
        var outcome = HandoffOutcome.none
        private(set) var calls: [(text: String, capturedAt: Date)] = []

        func process(text: String, capturedAt: Date) async -> HandoffOutcome {
            calls.append((text, capturedAt))
            return outcome
        }
    }

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
        func write(_ captured: CapturedMessage, to folder: URL, mode: TriageMode) async -> WriteResult {
            result
        }
    }

    private let availableGuard = DestinationGuard(directoryExists: { _ in true }, isVolumeRoot: { _ in true })
    private let absentGuard: DestinationGuard = {
        DestinationGuard(directoryExists: { path in !path.hasPrefix("/Volumes/") }, isVolumeRoot: { _ in false })
    }()

    private func makeAppState(triageMode: TriageMode = .full) -> AppState {
        let appState = AppState(supportDirectory: support)
        appState.settings.update {
            $0.outputFolder = output
            $0.paused = false
            $0.relayEnabled = true
            $0.triageMode = triageMode
            $0.replyMode = .all
        }
        appState.state.update { $0.automationPrePromptShown = true }
        return appState
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

    private func makeBatchProcessor(
        appState: AppState,
        writer: FileWriting,
        sender: FakeSender,
        spy: SpyHandoff,
        destinationGuard: DestinationGuard
    ) -> BatchProcessor {
        let replier = Replier(
            sender: sender,
            echoGuard: EchoGuard(stateStore: appState.state),
            notifications: FakeNotifications(),
            stateStore: appState.state,
            appState: appState,
            prePromptHandler: { true }
        )
        return BatchProcessor(
            appState: appState,
            writer: writer,
            replier: replier,
            echoGuard: EchoGuard(stateStore: appState.state),
            contentDedupCache: ContentDedupCache(stateStore: appState.state),
            spool: SpoolStore(directory: root.appendingPathComponent("Spool", isDirectory: true), stateStore: appState.state),
            destinationGuard: destinationGuard,
            handoff: spy,
            selfHandlesProvider: { ["+15555550100"] },
            selfChatGuidProvider: { nil },
            advanceWatermark: { _ in }
        )
    }

    // MARK: - Seam 1: BatchProcessor (live iMessage)

    func testWriteSuccessFiresHandoffOnceWithTextAndCaptureTime() async {
        let appState = makeAppState()
        let spy = SpyHandoff()
        spy.outcome = HandoffOutcome(reminderCreated: true, eventCreated: false)
        let sender = FakeSender()
        let processor = makeBatchProcessor(
            appState: appState, writer: FakeWriter(), sender: sender, spy: spy, destinationGuard: availableGuard
        )
        let e = event(rowid: 42, text: "remind me to water the plants")

        await processor.process(batch: [e])

        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls.first?.text, "remind me to water the plants")
        XCTAssertEqual(spy.calls.first?.capturedAt, e.dateUTC, "dates anchor to the capture's own timestamp")
        XCTAssertEqual(sender.sent.first?.text, "✅ Saved · Reminder created", "the outcome suffixes the confirmation")
    }

    func testSpoolBranchDoesNotFireHandoff() async {
        let appState = makeAppState()
        appState.settings.update { $0.outputFolder = URL(fileURLWithPath: "/Volumes/Phantom-\(UUID().uuidString)/Notes") }
        let spy = SpyHandoff()
        let sender = FakeSender()
        let processor = makeBatchProcessor(
            appState: appState, writer: FakeWriter(), sender: sender, spy: spy, destinationGuard: absentGuard
        )

        await processor.process(batch: [event(rowid: 43, text: "remind me to water the plants")])

        XCTAssertTrue(spy.calls.isEmpty, "the note isn't filed yet — the flush seam owns the handoff")
        XCTAssertEqual(sender.sent.first?.text, "✅ Queued — destination offline")
    }

    func testWriteFailureDoesNotFireHandoff() async {
        let appState = makeAppState()
        let spy = SpyHandoff()
        let writer = FakeWriter()
        writer.result = WriteResult(outcome: .failure(reason: "Disk full"), failedAttachments: [])
        let processor = makeBatchProcessor(
            appState: appState, writer: writer, sender: FakeSender(), spy: spy, destinationGuard: availableGuard
        )

        await processor.process(batch: [event(rowid: 44, text: "remind me to water the plants")])

        XCTAssertTrue(spy.calls.isEmpty)
    }

    // MARK: - Seam 2: RelayProcessor

    func testRelayFilingFiresHandoffWithRelayTimestamp() async throws {
        for mode in [TriageMode.full, .raw] {
            let appState = makeAppState(triageMode: mode)
            let spy = SpyHandoff()
            let processor = RelayProcessor(
                appState: appState,
                filer: RelayFiler(),
                ledger: RelayFiledLedger(stateStore: appState.state),
                triageLedger: TriageLedger(stateStore: appState.state),
                handoff: spy
            )
            let relay = root.appendingPathComponent("Relay-\(mode.rawValue)", isDirectory: true)
            try fm.createDirectory(at: relay, withIntermediateDirectories: true)
            // Distinct name per mode: both iterations share the support dir, so
            // the persisted relay ledger would otherwise drain the second one.
            let baseName = mode == .full ? "2026-07-06T15-14-42Z Water Plants" : "2026-07-06T16-14-42Z Water Plants"
            let name = baseName + ".txt"
            let txtURL = relay.appendingPathComponent(name)
            try "remind me to water the plants tomorrow".write(to: txtURL, atomically: true, encoding: .utf8)
            let candidate = RelayCandidate(
                txtURL: txtURL, audioURL: nil, relayFilename: name,
                baseName: baseName
            )

            await processor.process(batch: RelayScanBatch(candidates: [candidate], orphanAudio: []))

            XCTAssertEqual(spy.calls.count, 1, "mode \(mode.rawValue)")
            XCTAssertEqual(spy.calls.first?.text, "remind me to water the plants tomorrow")
            XCTAssertEqual(
                spy.calls.first?.capturedAt,
                RelayWatcher.parseRelayTimestamp(name),
                "capturedAt is the relay filename stamp, not filing time"
            )
        }
    }

    func testRelayLedgerHitDrainDoesNotFireHandoff() async throws {
        let appState = makeAppState()
        let spy = SpyHandoff()
        let ledger = RelayFiledLedger(stateStore: appState.state)
        let processor = RelayProcessor(
            appState: appState,
            filer: RelayFiler(),
            ledger: ledger,
            triageLedger: TriageLedger(stateStore: appState.state),
            handoff: spy
        )
        let relay = root.appendingPathComponent("Relay-ghost", isDirectory: true)
        try fm.createDirectory(at: relay, withIntermediateDirectories: true)
        let name = "2026-07-06T15-14-42Z Water Plants.txt"
        let txtURL = relay.appendingPathComponent(name)
        try "remind me to water the plants".write(to: txtURL, atomically: true, encoding: .utf8)
        ledger.record(relayFilename: name)

        let candidate = RelayCandidate(
            txtURL: txtURL, audioURL: nil, relayFilename: name,
            baseName: "2026-07-06T15-14-42Z Water Plants"
        )
        await processor.process(batch: RelayScanBatch(candidates: [candidate], orphanAudio: []))

        XCTAssertTrue(spy.calls.isEmpty, "an iCloud re-sync ghost drains without re-firing the handoff")
    }

    // MARK: - Seam 3: DestinationMonitor (spool flush)

    func testFlushSuccessFiresHandoffWithSpoolMetadataTime() async throws {
        let appState = makeAppState()
        let spy = SpyHandoff()
        let spool = SpoolStore(directory: root.appendingPathComponent("Spool-flush", isDirectory: true), stateStore: appState.state)
        let capturedAt = Date(timeIntervalSince1970: 1_752_000_000)
        _ = try await spool.add(
            text: "remind me to water the plants", capturedAt: capturedAt, source: .raptureMac, attachments: []
        )
        let monitor = DestinationMonitor(
            appState: appState,
            spool: spool,
            flusher: SpoolFlusher(),
            ledger: SpoolFiledLedger(stateStore: appState.state),
            destinationGuard: availableGuard,
            handoff: spy
        )

        await monitor.tick()

        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls.first?.text, "remind me to water the plants")
        XCTAssertEqual(spy.calls.first?.capturedAt, capturedAt, "capturedAt comes verbatim from the spool metadata")
        XCTAssertTrue(spool.isEmpty)
    }

    func testFlushLedgerHitResumeDoesNotFireHandoff() async throws {
        let appState = makeAppState()
        let spy = SpyHandoff()
        let spool = SpoolStore(directory: root.appendingPathComponent("Spool-resume", isDirectory: true), stateStore: appState.state)
        let item = try await spool.add(
            text: "remind me to water the plants", capturedAt: Date(timeIntervalSince1970: 1_752_000_000),
            source: .raptureMac, attachments: []
        )
        let ledger = SpoolFiledLedger(stateStore: appState.state)
        // Crash resume: the item filed before a crash but was never removed.
        ledger.record(itemName: item.name)
        let monitor = DestinationMonitor(
            appState: appState,
            spool: spool,
            flusher: SpoolFlusher(),
            ledger: ledger,
            destinationGuard: availableGuard,
            handoff: spy
        )

        await monitor.tick()

        XCTAssertTrue(spy.calls.isEmpty, "delete-only resume must not re-fire the handoff")
        XCTAssertTrue(spool.isEmpty)
    }

    // MARK: - Seam 4: TriageProcessor (hand-drop/backlog)

    func testTriageConversionFiresHandoffWithParsedCaptureTime() async throws {
        let appState = makeAppState()
        let spy = SpyHandoff()
        let processor = TriageProcessor(
            appState: appState,
            ledger: TriageLedger(stateStore: appState.state),
            handoff: spy
        )
        let name = "2026-07-06T15-14-42Z.txt"
        try "remind me to water the plants tomorrow".write(
            to: output.appendingPathComponent(name), atomically: true, encoding: .utf8
        )

        await processor.process(batch: TriageScanBatch(candidates: [TriageCandidate(filename: name)]))

        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls.first?.text, "remind me to water the plants tomorrow")
        XCTAssertEqual(
            spy.calls.first?.capturedAt,
            CaptureContract.parseSourceFilename(name).capturedAt,
            "a backlog note anchors to its own (possibly old) capture stamp"
        )
    }

    func testTriageGhostDrainDoesNotFireHandoff() async throws {
        let appState = makeAppState()
        let spy = SpyHandoff()
        let ledger = TriageLedger(stateStore: appState.state)
        let processor = TriageProcessor(appState: appState, ledger: ledger, handoff: spy)
        let name = "2026-07-06T15-14-42Z.txt"

        // First conversion fires once.
        try "remind me to water the plants".write(
            to: output.appendingPathComponent(name), atomically: true, encoding: .utf8
        )
        await processor.process(batch: TriageScanBatch(candidates: [TriageCandidate(filename: name)]))
        XCTAssertEqual(spy.calls.count, 1)

        // Sync ghost (same name + bytes) drains without a second handoff.
        try "remind me to water the plants".write(
            to: output.appendingPathComponent(name), atomically: true, encoding: .utf8
        )
        await processor.process(batch: TriageScanBatch(candidates: [TriageCandidate(filename: name)]))
        XCTAssertEqual(spy.calls.count, 1, "ledger-hit ghost drains never re-fire")
    }

    func testTriagePassesFooterStrippedBody() async throws {
        let appState = makeAppState()
        let spy = SpyHandoff()
        let processor = TriageProcessor(
            appState: appState,
            ledger: TriageLedger(stateStore: appState.state),
            handoff: spy
        )
        let name = "2026-07-06T15-14-42Z.txt"
        let attachmentFolder = output.appendingPathComponent("2026-07-06T15-14-42Z", isDirectory: true)
        try fm.createDirectory(at: attachmentFolder, withIntermediateDirectories: true)
        try Data([0x01]).write(to: attachmentFolder.appendingPathComponent("photo.heic"))
        let body = "remind me to water the plants\n\nAttachments:\n- 2026-07-06T15-14-42Z/photo.heic"
        try body.write(to: output.appendingPathComponent(name), atomically: true, encoding: .utf8)

        await processor.process(batch: TriageScanBatch(candidates: [TriageCandidate(filename: name)]))

        XCTAssertEqual(spy.calls.first?.text, "remind me to water the plants", "attachment footers aren't prose")
    }

    // MARK: - Reply suffix composition

    func testHandoffSuffixTable() {
        let success = WriteResult.Outcome.success(URL(fileURLWithPath: "/tmp/x.md"))
        XCTAssertEqual(
            Replier.composeReplyText(replyMode: .all, outcome: success, handoff: .none),
            "✅ Saved"
        )
        XCTAssertEqual(
            Replier.composeReplyText(
                replyMode: .all, outcome: success,
                handoff: HandoffOutcome(reminderCreated: true, eventCreated: false)
            ),
            "✅ Saved · Reminder created"
        )
        XCTAssertEqual(
            Replier.composeReplyText(
                replyMode: .all, outcome: success,
                handoff: HandoffOutcome(reminderCreated: false, eventCreated: true)
            ),
            "✅ Saved · Event created"
        )
        XCTAssertEqual(
            Replier.composeReplyText(
                replyMode: .all, outcome: success,
                handoff: HandoffOutcome(reminderCreated: true, eventCreated: true)
            ),
            "✅ Saved · Reminder + event created"
        )
        // The suffix never resurrects a suppressed reply tier.
        XCTAssertNil(Replier.composeReplyText(
            replyMode: .errorsOnly, outcome: success,
            handoff: HandoffOutcome(reminderCreated: true, eventCreated: true)
        ))
        XCTAssertNil(Replier.composeReplyText(
            replyMode: .off, outcome: success,
            handoff: HandoffOutcome(reminderCreated: true, eventCreated: true)
        ))
    }
}
