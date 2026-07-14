import XCTest
@testable import Rapture

/// Seam-level invariants for AI triage, mirroring `HandoffSeamTests`: the
/// processors forward the composer's `WriteResult.ai` into the handoff seam,
/// and paths that don't compose (spool enqueue) never consult AI.
@MainActor
final class AITriageSeamTests: XCTestCase {

    private let fm = FileManager.default
    private var root: URL!
    private var output: URL!
    private var support: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("ai-seam-\(UUID().uuidString)", isDirectory: true)
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

    @MainActor
    private final class RecordingHandoff: HandoffProcessing {
        private(set) var receivedAI: [AITriageOutput?] = []
        func process(text: String, capturedAt: Date, ai: AITriageOutput?) async -> HandoffOutcome {
            receivedAI.append(ai)
            return .none
        }
    }

    private final class FakeSender: AppleScriptSending, @unchecked Sendable {
        func send(text: String, toChatGuid chatGuid: String) async throws {}
    }

    private final class FakeNotifications: NotificationDispatching, @unchecked Sendable {
        func send(title: String, body: String) async {}
    }

    private let availableGuard = DestinationGuard(directoryExists: { _ in true }, isVolumeRoot: { _ in true })
    private let absentGuard = DestinationGuard(
        directoryExists: { path in !path.hasPrefix("/Volumes/") }, isVolumeRoot: { _ in false }
    )

    private var taskOutput: AITriageOutput {
        var out = AITriageOutput()
        out.classification = .task
        out.title = "Water the plants"
        return out
    }

    private func makeAppState() -> AppState {
        let appState = AppState(supportDirectory: support)
        appState.settings.update {
            $0.outputFolder = output
            $0.triageMode = .full
            $0.replyMode = .off
        }
        appState.state.update { $0.automationPrePromptShown = true }
        return appState
    }

    private func event(rowid: Int64, text: String) -> MessageEvent {
        MessageEvent(
            rowid: rowid, guid: "guid-\(rowid)", text: text, attributedBody: nil,
            dateAppleNs: rowid * 1_000_000_000, isFromMe: false, cacheHasAttachments: false,
            service: "iMessage", handleId: "+15555550100", chatGuid: "iMessage;-;chat-self",
            chatStyle: 45, attachments: []
        )
    }

    private func makeBatchProcessor(
        appState: AppState,
        ai: FakeAITriage,
        handoff: RecordingHandoff,
        destinationGuard: DestinationGuard
    ) -> BatchProcessor {
        let replier = Replier(
            sender: FakeSender(),
            echoGuard: EchoGuard(stateStore: appState.state),
            notifications: FakeNotifications(),
            stateStore: appState.state,
            appState: appState,
            prePromptHandler: { true }
        )
        return BatchProcessor(
            appState: appState,
            writer: FileWriter(ai: ai),
            replier: replier,
            echoGuard: EchoGuard(stateStore: appState.state),
            contentDedupCache: ContentDedupCache(stateStore: appState.state),
            spool: SpoolStore(directory: root.appendingPathComponent("Spool", isDirectory: true), stateStore: appState.state),
            destinationGuard: destinationGuard,
            handoff: handoff,
            selfHandlesProvider: { ["+15555550100"] },
            selfChatGuidProvider: { nil },
            advanceWatermark: { _ in }
        )
    }

    // MARK: - Seam 1: BatchProcessor

    func testBatchProcessorForwardsAIResultToHandoff() async {
        let appState = makeAppState()
        let ai = FakeAITriage(output: taskOutput)
        let handoff = RecordingHandoff()
        let processor = makeBatchProcessor(
            appState: appState, ai: ai, handoff: handoff, destinationGuard: availableGuard
        )

        await processor.process(batch: [event(rowid: 42, text: "water the plants please")])

        XCTAssertEqual(ai.calls.count, 1, "AI consulted exactly once per composed capture")
        XCTAssertEqual(handoff.receivedAI, [taskOutput])
    }

    func testBatchProcessorSpoolEnqueueNeverConsultsAI() async {
        let appState = makeAppState()
        appState.settings.update { $0.outputFolder = URL(fileURLWithPath: "/Volumes/Phantom-\(UUID().uuidString)/Notes") }
        let ai = FakeAITriage(output: taskOutput)
        let handoff = RecordingHandoff()
        let processor = makeBatchProcessor(
            appState: appState, ai: ai, handoff: handoff, destinationGuard: absentGuard
        )

        await processor.process(batch: [event(rowid: 43, text: "water the plants please")])

        XCTAssertTrue(ai.calls.isEmpty, "AI runs at flush, when the note actually composes")
        XCTAssertTrue(handoff.receivedAI.isEmpty)
    }

    // MARK: - Seam 2: RelayProcessor

    func testRelayProcessorForwardsAIResultToHandoff() async throws {
        let appState = makeAppState()
        let ai = FakeAITriage(output: taskOutput)
        let handoff = RecordingHandoff()
        let processor = RelayProcessor(
            appState: appState,
            filer: RelayFiler(ai: ai),
            ledger: RelayFiledLedger(stateStore: appState.state),
            triageLedger: TriageLedger(stateStore: appState.state),
            handoff: handoff
        )
        let relay = root.appendingPathComponent("Relay", isDirectory: true)
        try fm.createDirectory(at: relay, withIntermediateDirectories: true)
        let baseName = "2026-07-06T15-14-42Z"
        let txtURL = relay.appendingPathComponent(baseName + ".txt")
        try "water the plants please".write(to: txtURL, atomically: true, encoding: .utf8)

        await processor.process(batch: RelayScanBatch(
            candidates: [RelayCandidate(txtURL: txtURL, audioURL: nil, relayFilename: baseName + ".txt", baseName: baseName)],
            orphanAudio: []
        ))

        XCTAssertEqual(ai.calls.count, 1)
        XCTAssertEqual(handoff.receivedAI, [taskOutput])
    }

    // MARK: - Seam 3: DestinationMonitor (spool flush)

    func testSpoolFlushForwardsAIResultToHandoff() async throws {
        let appState = makeAppState()
        let ai = FakeAITriage(output: taskOutput)
        let handoff = RecordingHandoff()
        let spool = SpoolStore(directory: root.appendingPathComponent("Spool-flush", isDirectory: true), stateStore: appState.state)
        _ = try await spool.add(
            text: "water the plants please",
            capturedAt: Date(timeIntervalSince1970: 1_752_000_000),
            source: .raptureMac,
            attachments: []
        )
        let monitor = DestinationMonitor(
            appState: appState,
            spool: spool,
            flusher: SpoolFlusher(ai: ai),
            ledger: SpoolFiledLedger(stateStore: appState.state),
            destinationGuard: availableGuard,
            handoff: handoff
        )

        await monitor.tick()

        XCTAssertEqual(ai.calls.count, 1)
        XCTAssertEqual(handoff.receivedAI, [taskOutput])
    }

    // MARK: - Seam 4: TriageProcessor (covered in AITriageComposerTests) — ghost drains

    func testTriageGhostDrainDoesNotConsultAI() async throws {
        let appState = makeAppState()
        let ai = FakeAITriage(output: taskOutput)
        let ledger = TriageLedger(stateStore: appState.state)
        let processor = TriageProcessor(appState: appState, ledger: ledger, ai: ai)
        let name = "2026-07-06T15-14-42Z.txt"

        try "water the plants please".write(to: output.appendingPathComponent(name), atomically: true, encoding: .utf8)
        await processor.process(batch: TriageScanBatch(candidates: [TriageCandidate(filename: name)]))
        XCTAssertEqual(ai.calls.count, 1)

        // Sync ghost (same name + bytes): drained without a second AI call.
        try "water the plants please".write(to: output.appendingPathComponent(name), atomically: true, encoding: .utf8)
        await processor.process(batch: TriageScanBatch(candidates: [TriageCandidate(filename: name)]))
        XCTAssertEqual(ai.calls.count, 1, "no retroactive or repeat AI on ledger-hit drains")
    }
}
