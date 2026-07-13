import XCTest
@testable import Rapture

/// Full-mode `RelayProcessor` behavior: the triage ledger records where each relay
/// note landed, and orphan audio is routed to that location. Uses per-test temp
/// dirs and an injected support directory (never the live container).
@MainActor
final class RelayProcessorTriageTests: XCTestCase {

    private let fm = FileManager.default
    private var root: URL!
    private var relay: URL!
    private var output: URL!
    private var support: URL!

    private let baseName = "2026-07-06T15-14-42Z Grocery Ideas"
    private var txtName: String { baseName + ".txt" }
    private var m4aName: String { baseName + ".m4a" }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("relay-proc-triage-\(UUID().uuidString)", isDirectory: true)
        relay = root.appendingPathComponent("relay", isDirectory: true)
        output = root.appendingPathComponent("Rapture Notes", isDirectory: true)
        support = root.appendingPathComponent("Support", isDirectory: true)
        for dir in [relay, output, support] {
            try fm.createDirectory(at: dir!, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
    }

    private func makeAppState() -> AppState {
        let appState = AppState(supportDirectory: support)
        appState.settings.update {
            $0.outputFolder = output
            $0.paused = false
            $0.relayEnabled = true
            $0.triageMode = .full
        }
        return appState
    }

    private func makeProcessor(appState: AppState) -> RelayProcessor {
        RelayProcessor(
            appState: appState,
            filer: RelayFiler(),
            ledger: RelayFiledLedger(stateStore: appState.state),
            triageLedger: TriageLedger(stateStore: appState.state)
        )
    }

    func testFullModeFilingRecordsTriageEntryWithNoteLocation() async throws {
        let appState = makeAppState()
        let processor = makeProcessor(appState: appState)
        let txtURL = relay.appendingPathComponent(txtName)
        try "Milk and eggs".write(to: txtURL, atomically: true, encoding: .utf8)

        await processor.process(batch: RelayScanBatch(
            candidates: [RelayCandidate(txtURL: txtURL, audioURL: nil, relayFilename: txtName, baseName: baseName)],
            orphanAudio: []
        ))

        let entry = try XCTUnwrap(
            appState.state.state.triagedRecords.first { $0.sourceFilename == txtName },
            "full-mode relay filing records a triage entry"
        )
        XCTAssertTrue(entry.mdRelativePath.hasPrefix("Notes/"), "got \(entry.mdRelativePath)")
        XCTAssertTrue(entry.mdRelativePath.hasSuffix(" Grocery Ideas.md"))
        XCTAssertFalse(entry.contentHash.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent(entry.mdRelativePath).path))
        XCTAssertFalse(fm.fileExists(atPath: txtURL.path), "relay copy drained")
    }

    func testOrphanAudioLandsNextToItsTriagedNote() async throws {
        let appState = makeAppState()
        let processor = makeProcessor(appState: appState)

        // First: the note files text-only (audio not yet synced).
        let txtURL = relay.appendingPathComponent(txtName)
        try "Milk and eggs".write(to: txtURL, atomically: true, encoding: .utf8)
        await processor.process(batch: RelayScanBatch(
            candidates: [RelayCandidate(txtURL: txtURL, audioURL: nil, relayFilename: txtName, baseName: baseName)],
            orphanAudio: []
        ))
        let entry = try XCTUnwrap(appState.state.state.triagedRecords.first { $0.sourceFilename == txtName })

        // Later: the audio arrives alone and is treated as an orphan.
        let audioURL = relay.appendingPathComponent(m4aName)
        try Data([0x0A]).write(to: audioURL)
        await processor.process(batch: RelayScanBatch(candidates: [], orphanAudio: [audioURL]))

        let noteAttachmentDir = output
            .appendingPathComponent(entry.mdRelativePath)
            .deletingPathExtension()
        XCTAssertTrue(
            fm.fileExists(atPath: noteAttachmentDir.appendingPathComponent(m4aName).path),
            "orphan audio lands in the triaged note's own attachment folder, not a root folder"
        )
        XCTAssertFalse(fm.fileExists(atPath: output.appendingPathComponent(baseName, isDirectory: true).path),
                       "no disconnected root folder is created")
        XCTAssertFalse(fm.fileExists(atPath: audioURL.path), "relay audio drained")
    }

    func testOrphanAudioFallsBackToRootWhenNoteWasDeleted() async throws {
        let appState = makeAppState()
        let processor = makeProcessor(appState: appState)

        // The note files text-only, then the user deletes it in Finder.
        let txtURL = relay.appendingPathComponent(txtName)
        try "Milk and eggs".write(to: txtURL, atomically: true, encoding: .utf8)
        await processor.process(batch: RelayScanBatch(
            candidates: [RelayCandidate(txtURL: txtURL, audioURL: nil, relayFilename: txtName, baseName: baseName)],
            orphanAudio: []
        ))
        let entry = try XCTUnwrap(appState.state.state.triagedRecords.first { $0.sourceFilename == txtName })
        try fm.removeItem(at: output.appendingPathComponent(entry.mdRelativePath))

        // Late audio must not resurrect the deleted note's folder.
        let audioURL = relay.appendingPathComponent(m4aName)
        try Data([0x0A]).write(to: audioURL)
        await processor.process(batch: RelayScanBatch(candidates: [], orphanAudio: [audioURL]))

        let resurrection = output.appendingPathComponent(entry.mdRelativePath).deletingPathExtension()
        XCTAssertFalse(fm.fileExists(atPath: resurrection.path),
                       "a deleted note's attachment folder is never recreated")
        XCTAssertTrue(
            fm.fileExists(atPath: output.appendingPathComponent(baseName, isDirectory: true).appendingPathComponent(m4aName).path),
            "audio falls back to the legacy root placement"
        )
    }
}
