import XCTest
@testable import Rapture

/// Meeting relay parts end-to-end through `RelayProcessor` with the real
/// `MeetingFiler`, against per-test temp dirs and an injected support
/// directory (never the live container).
@MainActor
final class RelayProcessorMeetingTests: XCTestCase {

    private let fm = FileManager.default
    private var root: URL!
    private var relay: URL!
    private var output: URL!
    private var support: URL!

    private let meetingId = "0C6B2A4E-9F1D-4E51-A7C3-2B8D5E9F1A10"
    private let transcriptBase = "2026-09-29T18-30-00Z Meeting, Sep 29, 2-30 PM"
    private let summaryBase = "2026-09-29T18-30-00Z Budget planning"

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("relay-meeting-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Harness

    @MainActor
    private final class SpyHandoff: HandoffProcessing {
        private(set) var calls: [String] = []
        func process(text: String, capturedAt: Date, ai: AITriageOutput?) async -> HandoffOutcome {
            calls.append(text)
            return .none
        }
    }

    private func makeAppState(mode: TriageMode = .full) -> AppState {
        let appState = AppState(supportDirectory: support)
        appState.settings.update {
            $0.outputFolder = output
            $0.paused = false
            $0.relayEnabled = true
            $0.triageMode = mode
        }
        return appState
    }

    private func makeProcessor(appState: AppState, ai: FakeAITriage? = nil, handoff: SpyHandoff? = nil) -> RelayProcessor {
        RelayProcessor(
            appState: appState,
            filer: RelayFiler(ai: ai),
            ledger: RelayFiledLedger(stateStore: appState.state),
            triageLedger: TriageLedger(stateStore: appState.state),
            handoff: handoff
        )
    }

    private var transcriptBody: String {
        "# Meeting, Sep 29, 2:30 PM\n\nDana · 0:00\nOkay, let's start with the budget. Remember to call the bank tomorrow at 3pm.\n\nAlex · 1:12\nSounds good.\n"
    }

    private var summaryBody: String {
        "# Budget planning\n\n## Overview\nWe set the budget.\n\n## Decisions\n- Cap spend.\n\n## To-dos\n- [ ] Dana: remember to email the bank tomorrow\n\n## Transcript\n\n" + transcriptBody
    }

    private func marker(_ part: String, id: String? = nil) -> String {
        "<!-- rapture-meeting id=\(id ?? meetingId) part=\(part) -->\n"
    }

    @discardableResult
    private func writeRelay(_ base: String, _ text: String, audio: Bool = false) throws -> RelayCandidate {
        let txt = relay.appendingPathComponent(base + ".txt")
        try text.write(to: txt, atomically: true, encoding: .utf8)
        var audioURL: URL?
        if audio {
            audioURL = relay.appendingPathComponent(base + ".m4a")
            try Data([0x01, 0x02]).write(to: audioURL!)
        }
        return RelayCandidate(txtURL: txt, audioURL: audioURL, relayFilename: base + ".txt", baseName: base)
    }

    private func meetingsDir() -> URL { output.appendingPathComponent("Meetings", isDirectory: true) }

    private func meetingNotes() throws -> [URL] {
        guard fm.fileExists(atPath: meetingsDir().path) else { return [] }
        return try fm.contentsOfDirectory(at: meetingsDir(), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
    }

    private func onlyNote() throws -> (url: URL, text: String) {
        let notes = try meetingNotes()
        XCTAssertEqual(notes.count, 1, "exactly one meeting note, got \(notes.map(\.lastPathComponent))")
        let url = try XCTUnwrap(notes.first)
        return (url, try String(contentsOf: url, encoding: .utf8))
    }

    private func run(_ processor: RelayProcessor, _ candidates: [RelayCandidate], orphanAudio: [URL] = []) async {
        await processor.process(batch: RelayScanBatch(candidates: candidates, orphanAudio: orphanAudio))
    }

    // MARK: - Transcript

    func testTranscriptFilesAsMeetingWithoutAIOrHandoff() async throws {
        let appState = makeAppState()
        let ai = FakeAITriage()
        let handoff = SpyHandoff()
        let processor = makeProcessor(appState: appState, ai: ai, handoff: handoff)
        let candidate = try writeRelay(transcriptBase, marker("transcript") + transcriptBody, audio: true)

        await run(processor, [candidate])

        let note = try onlyNote()
        XCTAssertTrue(note.url.lastPathComponent.hasSuffix(" Meeting, Sep 29, 2-30 PM.md"), note.url.lastPathComponent)
        XCTAssertTrue(note.text.contains("type: meeting\nmeeting_id: \(meetingId)\n"))
        XCTAssertTrue(note.text.contains("source: rapture-ios\n"))
        XCTAssertFalse(note.text.contains("rapture-meeting"), "marker is stripped")
        XCTAssertTrue(note.text.contains("---\n\n" + transcriptBody), "body is verbatim")
        let audioName = transcriptBase + ".m4a"
        let folderName = note.url.deletingPathExtension().lastPathComponent
        XCTAssertTrue(note.text.hasSuffix("Attachments:\n- [\(audioName)](<\(folderName)/\(audioName)>)\n"))
        XCTAssertTrue(fm.fileExists(atPath: meetingsDir().appendingPathComponent(folderName).appendingPathComponent(audioName).path))
        XCTAssertTrue(ai.calls.isEmpty, "no AI triage for meetings")
        XCTAssertTrue(handoff.calls.isEmpty, "no Reminders/Calendar handoff for meetings")
        XCTAssertFalse(fm.fileExists(atPath: candidate.txtURL.path))
        XCTAssertFalse(fm.fileExists(atPath: candidate.audioURL!.path))
        XCTAssertEqual(appState.state.state.meetingRecords.first?.meetingId, meetingId)
    }

    func testFiftyThousandCharacterTranscriptFiles() async throws {
        let appState = makeAppState()
        let processor = makeProcessor(appState: appState)
        let long = String(repeating: "Dana · 0:00\nA fairly ordinary sentence about the budget and the plan.\n\n", count: 900)
        XCTAssertGreaterThan(long.count, 50_000)
        await run(processor, [try writeRelay(transcriptBase, marker("transcript") + "# Meeting\n\n" + long)])

        let note = try onlyNote()
        XCTAssertTrue(note.text.contains(long))
        XCTAssertNil(appState.relayLastError)
    }

    // MARK: - Summary replaces

    func testSummaryReplacesTranscriptRenamesAndKeepsAudio() async throws {
        let appState = makeAppState()
        let handoff = SpyHandoff()
        let processor = makeProcessor(appState: appState, handoff: handoff)
        await run(processor, [try writeRelay(transcriptBase, marker("transcript") + transcriptBody, audio: true)])
        let countAfterTranscript = appState.state.state.displayedTodayCount(at: Date())

        let summary = try writeRelay(summaryBase, marker("summary") + summaryBody)
        await run(processor, [summary])

        let note = try onlyNote()
        XCTAssertTrue(note.url.lastPathComponent.hasSuffix(" Budget planning.md"), note.url.lastPathComponent)
        XCTAssertTrue(note.text.contains("---\n\n# Budget planning\n\n## Overview"), "summary is on top")
        XCTAssertTrue(note.text.contains("## Transcript"))
        let folderName = note.url.deletingPathExtension().lastPathComponent
        let audioName = transcriptBase + ".m4a"
        XCTAssertTrue(note.text.hasSuffix("Attachments:\n- [\(audioName)](<\(folderName)/\(audioName)>)\n"),
                      "footer points at the renamed attachment folder")
        XCTAssertTrue(fm.fileExists(atPath: meetingsDir().appendingPathComponent(folderName).appendingPathComponent(audioName).path),
                      "audio moved with the note")
        let dirs = try fm.contentsOfDirectory(atPath: meetingsDir().path).filter { !$0.hasSuffix(".md") }
        XCTAssertEqual(dirs, [folderName], "no leftover attachment folder")
        XCTAssertFalse(fm.fileExists(atPath: summary.txtURL.path))
        XCTAssertEqual(appState.state.state.displayedTodayCount(at: Date()), countAfterTranscript,
                       "a replaced meeting is not a new note")
        let entry = try XCTUnwrap(appState.state.state.meetingRecords.first)
        XCTAssertEqual(entry.part, .summary)
        XCTAssertEqual(entry.noteRelativePath, "Meetings/" + note.url.lastPathComponent)
        XCTAssertTrue(handoff.calls.isEmpty, "summary to-dos never become Reminders")
    }

    func testRedoSummaryWithSameRelayNameStillReplaces() async throws {
        let appState = makeAppState()
        let processor = makeProcessor(appState: appState)
        await run(processor, [try writeRelay(summaryBase, marker("summary") + summaryBody)])
        XCTAssertTrue(RelayFiledLedger(stateStore: appState.state).contains(relayFilename: summaryBase + ".txt"),
                      "precondition: the name-based ledger knows this name")

        let redo = summaryBody.replacingOccurrences(of: "We set the budget.", with: "We set a smaller budget.")
        await run(processor, [try writeRelay(summaryBase, marker("summary") + redo)])

        let note = try onlyNote()
        XCTAssertTrue(note.text.contains("We set a smaller budget."))
        XCTAssertFalse(note.text.contains("We set the budget."))
    }

    func testResyncedOldSummaryNeverRollsBack() async throws {
        let appState = makeAppState()
        let processor = makeProcessor(appState: appState)
        let first = marker("summary") + summaryBody
        await run(processor, [try writeRelay(summaryBase, first)])
        let redo = summaryBody.replacingOccurrences(of: "We set the budget.", with: "Second take.")
        await run(processor, [try writeRelay("2026-09-29T18-30-00Z Budget planning v2", marker("summary") + redo)])

        // iCloud resurrects the first summary's relay copy.
        let ghost = try writeRelay(summaryBase, first)
        await run(processor, [ghost])

        let note = try onlyNote()
        XCTAssertTrue(note.text.contains("Second take."))
        XCTAssertTrue(note.url.lastPathComponent.hasSuffix(" Budget planning v2.md"))
        XCTAssertFalse(fm.fileExists(atPath: ghost.txtURL.path), "ghost is drained")
    }

    // MARK: - Order and races

    func testSummaryAlreadyWaitingFilesFirstAndDrainsTranscript() async throws {
        let appState = makeAppState()
        let processor = makeProcessor(appState: appState)
        let transcript = try writeRelay(transcriptBase, marker("transcript") + transcriptBody, audio: true)
        let summary = try writeRelay(summaryBase, marker("summary") + summaryBody)

        // Scan order puts the transcript first; the summary must still win.
        await run(processor, [transcript, summary])

        let note = try onlyNote()
        XCTAssertTrue(note.url.lastPathComponent.hasSuffix(" Budget planning.md"))
        XCTAssertTrue(note.text.contains("## Overview"))
        let audioName = transcriptBase + ".m4a"
        XCTAssertTrue(note.text.contains("Attachments:\n- [\(audioName)]"), "the transcript's audio joins the note")
        for url in [transcript.txtURL, transcript.audioURL!, summary.txtURL] {
            XCTAssertFalse(fm.fileExists(atPath: url.path), "\(url.lastPathComponent) drained")
        }
        XCTAssertEqual(appState.state.state.displayedTodayCount(at: Date()), 1)
    }

    func testTranscriptAfterSummaryIsDrainedNotFiled() async throws {
        let appState = makeAppState()
        let processor = makeProcessor(appState: appState)
        await run(processor, [try writeRelay(summaryBase, marker("summary") + summaryBody)])
        let transcript = try writeRelay(transcriptBase, marker("transcript") + transcriptBody)

        await run(processor, [transcript])

        let note = try onlyNote()
        XCTAssertTrue(note.text.contains("## Overview"), "summary stays")
        XCTAssertFalse(fm.fileExists(atPath: transcript.txtURL.path))
    }

    func testSummaryForUnknownMeetingFilesAsNewNote() async throws {
        let appState = makeAppState()
        let processor = makeProcessor(appState: appState)
        await run(processor, [try writeRelay(transcriptBase, marker("transcript") + transcriptBody)])
        let otherId = "11111111-2222-3333-4444-555555555555"

        await run(processor, [try writeRelay("2026-09-30T09-00-00Z Standup", marker("summary", id: otherId) + "# Standup\n\n## Overview\nx\n")])

        XCTAssertEqual(try meetingNotes().count, 2)
    }

    func testLateOrphanAudioJoinsMeetingNoteFooter() async throws {
        let appState = makeAppState()
        let processor = makeProcessor(appState: appState)
        await run(processor, [try writeRelay(transcriptBase, marker("transcript") + transcriptBody)])
        await run(processor, [try writeRelay(summaryBase, marker("summary") + summaryBody)])
        let audio = relay.appendingPathComponent(transcriptBase + ".m4a")
        try Data([0x09]).write(to: audio)

        await run(processor, [], orphanAudio: [audio])

        let note = try onlyNote()
        let folderName = note.url.deletingPathExtension().lastPathComponent
        XCTAssertTrue(note.text.hasSuffix("Attachments:\n- [\(transcriptBase).m4a](<\(folderName)/\(transcriptBase).m4a>)\n"))
        XCTAssertTrue(note.text.contains("## Overview"), "note text otherwise untouched")
        XCTAssertFalse(fm.fileExists(atPath: audio.path))
    }

    func testUserRenamedNoteIsFoundByMeetingId() async throws {
        let appState = makeAppState()
        let processor = makeProcessor(appState: appState)
        await run(processor, [try writeRelay(transcriptBase, marker("transcript") + transcriptBody)])
        let original = try onlyNote().url
        try fm.moveItem(at: original, to: meetingsDir().appendingPathComponent("My budget meeting.md"))

        await run(processor, [try writeRelay(summaryBase, marker("summary") + summaryBody)])

        let note = try onlyNote()
        XCTAssertTrue(note.text.contains("## Overview"))
    }

    // MARK: - Raw mode

    func testRawModeKeepsOneVerbatimFilePerMeeting() async throws {
        let appState = makeAppState(mode: .raw)
        let processor = makeProcessor(appState: appState)
        await run(processor, [try writeRelay(transcriptBase, marker("transcript") + transcriptBody, audio: true)])
        XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent(transcriptBase + ".txt").path))

        await run(processor, [try writeRelay(summaryBase, marker("summary") + summaryBody)])

        let txts = try fm.contentsOfDirectory(atPath: output.path).filter { $0.hasSuffix(".txt") }
        XCTAssertEqual(txts, [summaryBase + ".txt"], "renamed to the summary's relay name, one file")
        let text = try String(contentsOf: output.appendingPathComponent(summaryBase + ".txt"), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(marker("summary") + summaryBody), "raw contract: relay text verbatim")
        XCTAssertTrue(text.hasSuffix("Attachments:\n- \(summaryBase)/\(transcriptBase).m4a\n"))
        XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent(summaryBase).appendingPathComponent(transcriptBase + ".m4a").path))
        XCTAssertFalse(fm.fileExists(atPath: output.appendingPathComponent("Meetings").path))
    }

    // MARK: - Unmarked files unchanged

    func testUnmarkedRelayFileStillTakesTheOrdinaryPath() async throws {
        let appState = makeAppState()
        let handoff = SpyHandoff()
        let processor = makeProcessor(appState: appState, handoff: handoff)
        await run(processor, [try writeRelay("2026-09-29T18-31-00Z Errand", "# Errand\n\nRemember to call the bank tomorrow")])

        XCTAssertTrue(try meetingNotes().isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent("Notes").path))
        XCTAssertEqual(handoff.calls.count, 1, "ordinary notes still hand off")
        XCTAssertTrue(appState.state.state.meetingRecords.isEmpty)
    }

    // MARK: - Hand-drop / raw-mode leftover at the root

    func testRootMeetingTxtTriagesIntoMeetingsWithoutHandoff() async throws {
        let appState = makeAppState()
        let handoff = SpyHandoff()
        let ai = FakeAITriage()
        let meetingLedger = MeetingLedger(stateStore: appState.state)
        let processor = TriageProcessor(
            appState: appState,
            ledger: TriageLedger(stateStore: appState.state),
            handoff: handoff,
            ai: ai,
            meetingLedger: meetingLedger
        )
        let name = transcriptBase + ".txt"
        try (marker("transcript") + transcriptBody).write(to: output.appendingPathComponent(name), atomically: true, encoding: .utf8)

        await processor.process(batch: TriageScanBatch(candidates: [TriageCandidate(filename: name)]))

        let note = try onlyNote()
        XCTAssertTrue(note.text.contains("type: meeting\nmeeting_id: \(meetingId)\n"))
        XCTAssertFalse(note.text.contains("rapture-meeting"))
        XCTAssertTrue(handoff.calls.isEmpty)
        XCTAssertTrue(ai.calls.isEmpty)
        XCTAssertEqual(meetingLedger.entry(meetingId: meetingId)?.noteRelativePath, "Meetings/" + note.url.lastPathComponent)
    }
}
