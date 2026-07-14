import XCTest
@testable import Rapture

/// The four composers consulting `FakeAITriage`: AI fields applied (subfolder
/// routing, filename title, formatted body + `## Raw` verbatim), nil result =
/// deterministic output, links and raw mode never consult AI, relay-title
/// precedence, and the spool-enqueue exclusion is covered by seam tests.
@MainActor
final class AITriageComposerTests: XCTestCase {

    private let fm = FileManager.default
    private var root: URL!
    private var output: URL!
    private var support: URL!
    private var appState: AppState!

    private let capturedAt = Date(timeIntervalSince1970: 1_752_000_000)

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("ai-composer-\(UUID().uuidString)", isDirectory: true)
        output = root.appendingPathComponent("Notes", isDirectory: true)
        support = root.appendingPathComponent("Support", isDirectory: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        appState = AppState(supportDirectory: support)
        appState.settings.update {
            $0.outputFolder = output
            $0.triageMode = .full
        }
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
    }

    private func event(text: String) -> MessageEvent {
        MessageEvent(
            rowid: 1,
            guid: "guid-1",
            text: text,
            attributedBody: nil,
            dateAppleNs: Int64((capturedAt.timeIntervalSince1970 - 978_307_200) * 1_000_000_000),
            isFromMe: false,
            cacheHasAttachments: false,
            service: "iMessage",
            handleId: "+15555550100",
            chatGuid: "iMessage;-;chat-self",
            chatStyle: 45,
            attachments: []
        )
    }

    private var taskOutput: AITriageOutput {
        var out = AITriageOutput()
        out.classification = .task
        out.title = "Fix the garage door sensor"
        out.formattedBody = "Fix the garage door sensor. It sticks on cold mornings."
        return out
    }

    // MARK: - FileWriter

    func testFileWriterAppliesAIRoutingTitleAndRawSection() async throws {
        let ai = FakeAITriage(output: taskOutput)
        let writer = FileWriter(ai: ai)
        let rawText = "um okay fix the garage door sensor it sticks on cold mornings"
        let captured = CapturedMessage(event: event(text: rawText), decodedText: rawText, isCatchup: false)

        let result = await writer.write(captured, to: output, mode: .full)

        guard case .success(let url) = result.outcome else { return XCTFail("expected success") }
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Tasks")
        XCTAssertTrue(url.lastPathComponent.contains("Fix the garage door sensor"))
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("type: task"))
        XCTAssertTrue(contents.contains("Fix the garage door sensor. It sticks on cold mornings."))
        XCTAssertTrue(contents.contains("## Raw"))
        XCTAssertTrue(contents.contains(rawText), "verbatim dictation is never discarded")
        XCTAssertEqual(result.ai, taskOutput, "the result echoes the AI output for the handoff seam")
        XCTAssertEqual(ai.calls.count, 1)
        XCTAssertEqual(ai.calls.first?.capturedAt, captured.event.dateUTC)
    }

    func testFileWriterNilAIResultIsDeterministic() async throws {
        let ai = FakeAITriage(output: nil)
        let writerWithAI = FileWriter(ai: ai)
        let writerWithout = FileWriter()
        let rawText = "water the plants every other day"
        let captured = CapturedMessage(event: event(text: rawText), decodedText: rawText, isCatchup: false)

        let aiResult = await writerWithAI.write(captured, to: output, mode: .full)
        guard case .success(let aiURL) = aiResult.outcome else { return XCTFail() }
        let aiContents = try String(contentsOf: aiURL, encoding: .utf8)
        try fm.removeItem(at: aiURL)

        let plainResult = await writerWithout.write(captured, to: output, mode: .full)
        guard case .success(let plainURL) = plainResult.outcome else { return XCTFail() }
        let plainContents = try String(contentsOf: plainURL, encoding: .utf8)

        XCTAssertEqual(aiContents, plainContents, "nil AI result = byte-identical deterministic note")
        XCTAssertFalse(aiContents.contains("## Raw"))
        XCTAssertNil(aiResult.ai)
        XCTAssertEqual(ai.calls.count, 1)
    }

    func testFileWriterLinkCapturesNeverConsultAI() async {
        let ai = FakeAITriage(output: taskOutput)
        let writer = FileWriter(ai: ai)
        let rawText = "https://www.youtube.com/watch?v=abc123xyz"
        let captured = CapturedMessage(event: event(text: rawText), decodedText: rawText, isCatchup: false)

        let result = await writer.write(captured, to: output, mode: .full)

        guard case .success(let url) = result.outcome else { return XCTFail() }
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Links")
        XCTAssertTrue(ai.calls.isEmpty, "M5 enrichment keys off deterministic link types")
        XCTAssertNil(result.ai)
    }

    func testFileWriterRawModeNeverConsultsAI() async {
        let ai = FakeAITriage(output: taskOutput)
        let writer = FileWriter(ai: ai)
        let rawText = "water the plants"
        let captured = CapturedMessage(event: event(text: rawText), decodedText: rawText, isCatchup: false)

        let result = await writer.write(captured, to: output, mode: .raw)

        XCTAssertTrue(result.isSuccess)
        XCTAssertTrue(ai.calls.isEmpty)
    }

    // MARK: - RelayFiler

    func testRelayFilerRelayTitleBeatsAITitle() async throws {
        let ai = FakeAITriage(output: taskOutput)
        let filer = RelayFiler(ai: ai)
        let relay = root.appendingPathComponent("Relay", isDirectory: true)
        try fm.createDirectory(at: relay, withIntermediateDirectories: true)
        let baseName = "2026-07-06T15-14-42Z Garage Door"
        let txtURL = relay.appendingPathComponent(baseName + ".txt")
        try "fix the garage door sensor".write(to: txtURL, atomically: true, encoding: .utf8)
        let candidate = RelayCandidate(txtURL: txtURL, audioURL: nil, relayFilename: baseName + ".txt", baseName: baseName)

        let result = await filer.file(candidate, to: output, mode: .full)

        guard case .success(let url) = result.outcome else { return XCTFail() }
        XCTAssertTrue(url.lastPathComponent.contains("Garage Door"), "iPhone-derived title wins")
        XCTAssertFalse(url.lastPathComponent.contains("Fix the garage door sensor"))
        // The AI classification still routes the note.
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Tasks")
        XCTAssertEqual(ai.calls.count, 1)
    }

    func testRelayFilerAppliesAIWhenNoRelayTitle() async throws {
        let ai = FakeAITriage(output: taskOutput)
        let filer = RelayFiler(ai: ai)
        let relay = root.appendingPathComponent("Relay2", isDirectory: true)
        try fm.createDirectory(at: relay, withIntermediateDirectories: true)
        // Pure-timestamp basename → no iOS-derived title.
        let baseName = "2026-07-06T15-14-42Z"
        let txtURL = relay.appendingPathComponent(baseName + ".txt")
        try "fix the garage door sensor".write(to: txtURL, atomically: true, encoding: .utf8)
        let candidate = RelayCandidate(txtURL: txtURL, audioURL: nil, relayFilename: baseName + ".txt", baseName: baseName)

        let result = await filer.file(candidate, to: output, mode: .full)

        guard case .success(let url) = result.outcome else { return XCTFail() }
        XCTAssertTrue(url.lastPathComponent.contains("Fix the garage door sensor"))
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("type: task"))
        XCTAssertTrue(contents.contains("## Raw"))
    }

    // MARK: - SpoolFlusher

    func testSpoolFlusherAppliesAIWithMetadataCaptureTime() async throws {
        let ai = FakeAITriage(output: taskOutput)
        let flusher = SpoolFlusher(ai: ai)
        let spool = SpoolStore(directory: root.appendingPathComponent("Spool", isDirectory: true), stateStore: appState.state)
        let item = try await spool.add(
            text: "fix the garage door sensor", capturedAt: capturedAt, source: .raptureMac, attachments: []
        )

        let result = await flusher.file(item, to: output, mode: .full)

        guard case .success(let url) = result.outcome else { return XCTFail() }
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Tasks")
        XCTAssertEqual(ai.calls.first?.capturedAt, capturedAt, "AI anchors to the spooled capture's own time")
        XCTAssertEqual(result.ai, taskOutput)
    }

    // MARK: - TriageProcessor (inline composer)

    func testTriageProcessorAppliesAIAndForwardsToHandoff() async throws {
        let ai = FakeAITriage(output: taskOutput)
        let spy = SpyAIHandoffRecorder()
        let processor = TriageProcessor(
            appState: appState,
            ledger: TriageLedger(stateStore: appState.state),
            handoff: spy,
            ai: ai
        )
        let name = "2026-07-06T15-14-42Z.txt"
        try "um okay fix the garage door sensor it sticks".write(
            to: output.appendingPathComponent(name), atomically: true, encoding: .utf8
        )

        await processor.process(batch: TriageScanBatch(candidates: [TriageCandidate(filename: name)]))

        let tasks = output.appendingPathComponent("Tasks", isDirectory: true)
        let files = try fm.contentsOfDirectory(atPath: tasks.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].contains("Fix the garage door sensor"))
        let contents = try String(contentsOf: tasks.appendingPathComponent(files[0]), encoding: .utf8)
        XCTAssertTrue(contents.contains("type: task"))
        XCTAssertTrue(contents.contains("## Raw"))
        XCTAssertEqual(spy.receivedAI, [taskOutput], "the AI result rides into the handoff seam")
        XCTAssertEqual(ai.calls.count, 1)
    }

    func testTriageProcessorLinkNeverConsultsAI() async throws {
        let ai = FakeAITriage(output: taskOutput)
        let processor = TriageProcessor(
            appState: appState,
            ledger: TriageLedger(stateStore: appState.state),
            ai: ai
        )
        let name = "2026-07-06T15-14-42Z.txt"
        try "https://example.com/article".write(
            to: output.appendingPathComponent(name), atomically: true, encoding: .utf8
        )

        await processor.process(batch: TriageScanBatch(candidates: [TriageCandidate(filename: name)]))

        XCTAssertTrue(ai.calls.isEmpty)
        let links = output.appendingPathComponent("Links", isDirectory: true)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: links.path).count, 1)
    }
}

/// Records the `ai` argument forwarded into the handoff seam.
@MainActor
private final class SpyAIHandoffRecorder: HandoffProcessing {
    private(set) var receivedAI: [AITriageOutput?] = []
    func process(text: String, capturedAt: Date, ai: AITriageOutput?) async -> HandoffOutcome {
        receivedAI.append(ai)
        return .none
    }
}
