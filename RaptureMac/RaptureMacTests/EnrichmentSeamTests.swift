import XCTest
@testable import Rapture

/// A recording `LinkEnriching` spy for the seam tests.
@MainActor
final class SpyLinkEnriching: LinkEnriching {
    private(set) var calls: [(noteURL: URL, folder: URL, echo: LinkNoteEcho)] = []
    func noteFiled(noteURL: URL, in folder: URL, echo: LinkNoteEcho) {
        calls.append((noteURL, folder, echo))
    }
}

/// The enrichment seams: the three composers echo `WriteResult.link` for link
/// captures only, and `TriageProcessor` hands freshly-triaged link notes to
/// `LinkEnriching` (never ghost drains, never raw mode).
@MainActor
final class EnrichmentSeamTests: XCTestCase {

    private let fm = FileManager.default
    private var root: URL!
    private var output: URL!
    private var support: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("enrich-seam-\(UUID().uuidString)", isDirectory: true)
        output = root.appendingPathComponent("Rapture Notes", isDirectory: true)
        support = root.appendingPathComponent("Support", isDirectory: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
    }

    private let youtubeURL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

    private func captured(text: String) -> CapturedMessage {
        CapturedMessage(
            event: MessageEvent(
                rowid: 1,
                guid: "guid-\(UUID().uuidString)",
                text: text,
                attributedBody: nil,
                dateAppleNs: 0,
                isFromMe: false,
                cacheHasAttachments: false,
                service: "iMessage",
                handleId: "+15555550100",
                chatGuid: "iMessage;-;chat",
                chatStyle: 45,
                attachments: []
            ),
            decodedText: text,
            isCatchup: false
        )
    }

    // MARK: - Composer echoes

    func testFileWriterEchoesLinkForYouTubeCapture() async {
        let result = await FileWriter().write(captured(text: youtubeURL), to: output, mode: .full)
        XCTAssertEqual(result.link?.type, .youtubeLink)
        XCTAssertEqual(result.link?.rawMedia, youtubeURL)
    }

    func testFileWriterNoEchoForVoiceNoteOrRawMode() async {
        let voice = await FileWriter().write(captured(text: "plain thought"), to: output, mode: .full)
        XCTAssertNil(voice.link)
        let raw = await FileWriter().write(captured(text: youtubeURL), to: output, mode: .raw)
        XCTAssertNil(raw.link)
    }

    func testSpoolFlusherEchoesLinkWithMetadataCaptureTime() async throws {
        let capturedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let appState = AppState(supportDirectory: support)
        appState.settings.update { $0.outputFolder = output }
        let spool = SpoolStore(stateStore: appState.state)
        let item = try await spool.add(text: youtubeURL, capturedAt: capturedAt, source: .raptureMac)
        let result = await SpoolFlusher().file(item, to: output, mode: .full)
        XCTAssertEqual(result.link?.type, .youtubeLink)
        XCTAssertEqual(result.link?.capturedAt, capturedAt, "capture time verbatim from meta.json")
    }

    // MARK: - TriageProcessor direct call

    private func makeAppState(mode: TriageMode = .full) -> AppState {
        let appState = AppState(supportDirectory: support)
        appState.settings.update {
            $0.outputFolder = output
            $0.paused = false
            $0.triageMode = mode
            $0.linkEnrichmentEnabled = true
        }
        return appState
    }

    func testTriageProcessorHandsLinkNoteToEnrichment() async throws {
        let appState = makeAppState()
        let spy = SpyLinkEnriching()
        let processor = TriageProcessor(
            appState: appState,
            ledger: TriageLedger(stateStore: appState.state),
            enrichment: spy
        )
        try youtubeURL.write(to: output.appendingPathComponent("2026-07-13T15-00-00Z.txt"), atomically: true, encoding: .utf8)
        await processor.process(batch: TriageScanBatch(candidates: [TriageCandidate(filename: "2026-07-13T15-00-00Z.txt")]))

        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls.first?.echo.type, .youtubeLink)
        XCTAssertEqual(spy.calls.first?.echo.rawMedia, youtubeURL)
        XCTAssertTrue(spy.calls.first?.noteURL.path.contains("/Links/") == true)
    }

    func testTriageProcessorSkipsEnrichmentForVoiceNotesAndGhostDrains() async throws {
        let appState = makeAppState()
        let spy = SpyLinkEnriching()
        let ledger = TriageLedger(stateStore: appState.state)
        let processor = TriageProcessor(appState: appState, ledger: ledger, enrichment: spy)

        // Voice note: no enrichment.
        try "just a thought".write(to: output.appendingPathComponent("2026-07-13T15-00-00Z.txt"), atomically: true, encoding: .utf8)
        await processor.process(batch: TriageScanBatch(candidates: [TriageCandidate(filename: "2026-07-13T15-00-00Z.txt")]))
        XCTAssertTrue(spy.calls.isEmpty)

        // Ghost re-delivery of an already-triaged link: drained, not re-enriched.
        let name = "2026-07-13T16-00-00Z.txt"
        try youtubeURL.write(to: output.appendingPathComponent(name), atomically: true, encoding: .utf8)
        await processor.process(batch: TriageScanBatch(candidates: [TriageCandidate(filename: name)]))
        XCTAssertEqual(spy.calls.count, 1)
        try youtubeURL.write(to: output.appendingPathComponent(name), atomically: true, encoding: .utf8)
        await processor.process(batch: TriageScanBatch(candidates: [TriageCandidate(filename: name)]))
        XCTAssertEqual(spy.calls.count, 1, "ghost drain must not re-enqueue enrichment")
    }
}
