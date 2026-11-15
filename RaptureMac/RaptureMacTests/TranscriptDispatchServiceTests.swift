import XCTest
@testable import Rapture

/// Drives `TranscriptDispatchService` deterministically via the internal
/// `tick()`/`reconcile()` with a fake launcher, injected clock, temp-dir
/// AppState and real note files. No real claude, no network, no sleeps.
@MainActor
final class TranscriptDispatchServiceTests: XCTestCase {

    /// Mutable clock the @Sendable closure can read; written only from the
    /// main-actor test body before ticks.
    private final class ClockBox: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private let fm = FileManager.default
    private var root: URL!
    private var output: URL!
    private var support: URL!
    private var pipelineFolder: URL!
    private var clockBox: ClockBox!

    private let youtubeURL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    private let fingerprint = "yt:dQw4w9WgXcQ"

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("dispatch-\(UUID().uuidString)", isDirectory: true)
        output = root.appendingPathComponent("Rapture Notes", isDirectory: true)
        support = root.appendingPathComponent("Support", isDirectory: true)
        pipelineFolder = root.appendingPathComponent("pipeline-repo", isDirectory: true)
        try fm.createDirectory(at: output.appendingPathComponent("Links", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        try fm.createDirectory(at: pipelineFolder, withIntermediateDirectories: true)
        clockBox = ClockBox(Date(timeIntervalSince1970: 1_800_000_000))
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
    }

    // MARK: - Fixtures

    private var now: Date { clockBox.now }

    /// How a test wants the pipeline-folder setting to start out.
    private enum FolderSetting {
        /// The temp pipeline folder made in `setUp` (the working default).
        case ready
        case notSet
        case path(String)
    }

    private func makeAppState(autoTranscribe: Bool = true, folder: FolderSetting = .ready) -> AppState {
        let appState = AppState(supportDirectory: support)
        appState.settings.update {
            $0.outputFolder = output
            $0.paused = false
            $0.triageMode = .full
            $0.linkEnrichmentEnabled = true
            $0.autoTranscribeYouTube = autoTranscribe
            switch folder {
            case .ready: $0.transcriptPipelineFolder = pipelineFolder.path
            case .notSet: $0.transcriptPipelineFolder = nil
            case .path(let path): $0.transcriptPipelineFolder = path
            }
        }
        return appState
    }

    /// The service takes no folder: it reads `Settings.transcriptPipelineFolder`
    /// at every enqueue and every spawn.
    private func makeService(
        appState: AppState,
        launcher: FakeTranscriptSessionLauncher? = nil
    ) -> (TranscriptDispatchService, TranscriptDispatchLedger, FakeTranscriptSessionLauncher) {
        let launcher = launcher ?? FakeTranscriptSessionLauncher()
        let ledger = TranscriptDispatchLedger(stateStore: appState.state, clock: { [clockBox] in clockBox?.now ?? Date() })
        let service = TranscriptDispatchService(
            appState: appState,
            ledger: ledger,
            launcher: launcher,
            clock: { [clockBox] in clockBox?.now ?? Date() }
        )
        return (service, ledger, launcher)
    }

    private var missingFolder: URL {
        root.appendingPathComponent("nowhere", isDirectory: true)
    }

    @discardableResult
    private func fileNote(base: String = "2026-08-31 Some Video", body: String = "content") throws -> URL {
        let url = output.appendingPathComponent("Links/\(base).md")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func enqueue(_ service: TranscriptDispatchService, path: String = "Links/2026-08-31 Some Video.md") {
        service.captureEnriched(fingerprint: fingerprint, url: youtubeURL, noteRelativePath: path)
    }

    // MARK: - Enqueue guards

    func testCaptureEnrichedAppendsPendingEntry() {
        let appState = makeAppState()
        let (service, ledger, _) = makeService(appState: appState)
        enqueue(service)
        let entry = ledger.entry(fingerprint: fingerprint)
        XCTAssertEqual(entry?.status, .pending)
        XCTAssertEqual(entry?.url, youtubeURL)
        XCTAssertEqual(entry?.noteRelativePath, "Links/2026-08-31 Some Video.md")
        XCTAssertEqual(entry?.attempts, 0)
    }

    func testCaptureEnrichedIgnoresNonYouTube() {
        let appState = makeAppState()
        let (service, ledger, _) = makeService(appState: appState)
        service.captureEnriched(fingerprint: "url:https://example.com/post", url: "https://example.com/post", noteRelativePath: "Links/A.md")
        XCTAssertTrue(ledger.records.isEmpty)
    }

    func testCaptureEnrichedIgnoresWhenToggleOff() {
        let appState = makeAppState(autoTranscribe: false)
        let (service, ledger, _) = makeService(appState: appState)
        enqueue(service)
        XCTAssertTrue(ledger.records.isEmpty)
    }

    func testCaptureEnrichedSkipsWhenPipelineFolderNotSet() {
        // A new public install: toggle on (the default), no folder. The
        // feature is off — nothing queued, nothing spawned, no alert — and
        // each skipped capture writes exactly one log line.
        let appState = makeAppState(folder: .notSet)
        let (service, ledger, launcher) = makeService(appState: appState)
        enqueue(service)
        XCTAssertTrue(ledger.records.isEmpty, "not set → the feature is off; nothing is queued")
        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertNil(appState.transcriptDispatchLastError, "no alert per capture — Settings shows the folder state")
        XCTAssertEqual(service.skippedDispatchLogCount, 1)

        service.captureEnriched(fingerprint: "yt:other", url: "https://youtu.be/other", noteRelativePath: "Links/B.md")
        XCTAssertEqual(service.skippedDispatchLogCount, 2, "one log line for each skipped dispatch")
    }

    func testCaptureEnrichedTreatsBlankFolderAsNotSet() {
        let appState = makeAppState(folder: .path("   "))
        let (service, ledger, _) = makeService(appState: appState)
        enqueue(service)
        XCTAssertTrue(ledger.records.isEmpty)
        XCTAssertEqual(service.skippedDispatchLogCount, 1)
    }

    func testCaptureEnrichedSkipsWhenPipelineFolderMissing() {
        // The repo moved (or its drive is unplugged): never a silent stop.
        let appState = makeAppState(folder: .path(missingFolder.path))
        let (service, ledger, launcher) = makeService(appState: appState)
        enqueue(service)
        XCTAssertTrue(ledger.records.isEmpty)
        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertNil(appState.transcriptDispatchLastError)
        XCTAssertEqual(service.skippedDispatchLogCount, 1)
    }

    func testCaptureEnrichedSkipsWhenPipelineFolderIsAFile() throws {
        let file = root.appendingPathComponent("not-a-folder.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let appState = makeAppState(folder: .path(file.path))
        let (service, ledger, _) = makeService(appState: appState)
        enqueue(service)
        XCTAssertTrue(ledger.records.isEmpty, "a session cannot run in a file")
        XCTAssertEqual(service.skippedDispatchLogCount, 1)
    }

    func testCaptureEnrichedDoesNotLogSkipWhenToggleOff() {
        let appState = makeAppState(autoTranscribe: false, folder: .notSet)
        let (service, ledger, _) = makeService(appState: appState)
        enqueue(service)
        XCTAssertTrue(ledger.records.isEmpty)
        XCTAssertEqual(service.skippedDispatchLogCount, 0, "toggle off is the user's choice, not a skipped dispatch")
    }

    func testFolderSetWhileRunningAppliesToNextCaptureWithoutRestart() async throws {
        try fileNote()
        let appState = makeAppState(folder: .notSet)
        let (service, ledger, launcher) = makeService(appState: appState)
        enqueue(service)
        XCTAssertTrue(ledger.records.isEmpty, "skipped while not set")

        // The user picks the folder in Settings — same service, no restart.
        appState.settings.update { $0.transcriptPipelineFolder = pipelineFolder.path }
        enqueue(service)
        XCTAssertEqual(ledger.entry(fingerprint: fingerprint)?.status, .pending)

        await service.tick()
        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertEqual(launcher.launches[0].workingDirectory.path, pipelineFolder.path)
    }

    func testCaptureEnrichedIsIdempotentForDonePendingDispatched() {
        let appState = makeAppState()
        let (service, ledger, _) = makeService(appState: appState)
        for status in [TranscriptDispatchEntry.Status.done, .pending, .dispatched] {
            ledger.append(TranscriptDispatchEntry(
                fingerprint: fingerprint, url: youtubeURL, noteRelativePath: "Links/Old.md",
                status: status, createdAt: now))
            enqueue(service, path: "Links/New.md")
            XCTAssertEqual(ledger.records.count, 1)
            XCTAssertEqual(ledger.entry(fingerprint: fingerprint)?.status, status)
            XCTAssertEqual(ledger.entry(fingerprint: fingerprint)?.noteRelativePath, "Links/Old.md")
        }
    }

    func testCaptureEnrichedResetsFailedToPendingWithNewNote() {
        let appState = makeAppState()
        let (service, ledger, _) = makeService(appState: appState)
        ledger.append(TranscriptDispatchEntry(
            fingerprint: fingerprint, url: youtubeURL, noteRelativePath: "Links/Old.md",
            status: .failed, createdAt: now, attempts: 1, lastError: "boom"))
        enqueue(service, path: "Links/New.md")
        let entry = ledger.entry(fingerprint: fingerprint)
        XCTAssertEqual(entry?.status, .pending)
        XCTAssertEqual(entry?.noteRelativePath, "Links/New.md")
        XCTAssertNil(entry?.lastError)
        XCTAssertEqual(entry?.attempts, 1, "attempts history kept")
    }

    // MARK: - Spawn

    func testTickSpawnsOldestPendingFIFO() async throws {
        try fileNote(base: "2026-08-31 First")
        try fileNote(base: "2026-08-31 Second")
        let appState = makeAppState()
        let (service, ledger, launcher) = makeService(appState: appState)
        ledger.append(TranscriptDispatchEntry(
            fingerprint: "yt:first", url: "https://youtu.be/first",
            noteRelativePath: "Links/2026-08-31 First.md", status: .pending,
            createdAt: now.addingTimeInterval(-60)))
        ledger.append(TranscriptDispatchEntry(
            fingerprint: "yt:second", url: "https://youtu.be/second",
            noteRelativePath: "Links/2026-08-31 Second.md", status: .pending, createdAt: now))

        await service.tick()

        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertTrue(launcher.launches[0].prompt.contains("https://youtu.be/first"))
        XCTAssertTrue(launcher.launches[0].prompt.contains(
            output.appendingPathComponent("Links/2026-08-31 First.md").path))
        XCTAssertEqual(launcher.launches[0].workingDirectory.path, pipelineFolder.path,
                       "the session runs in the folder from Settings")
        let first = ledger.entry(fingerprint: "yt:first")
        XCTAssertEqual(first?.status, .dispatched)
        XCTAssertEqual(first?.dispatchedAt, now)
        XCTAssertEqual(first?.attempts, 1)
        XCTAssertEqual(ledger.entry(fingerprint: "yt:second")?.status, .pending)
    }

    func testTickNeverSpawnsWhileOneIsInFlight() async throws {
        try fileNote(base: "2026-08-31 Second")
        let appState = makeAppState()
        let (service, ledger, launcher) = makeService(appState: appState)
        launcher.running = true
        ledger.append(TranscriptDispatchEntry(
            fingerprint: "yt:first", url: "u", noteRelativePath: "Links/Nope.md",
            status: .dispatched, createdAt: now, dispatchedAt: now))
        ledger.append(TranscriptDispatchEntry(
            fingerprint: "yt:second", url: "u2",
            noteRelativePath: "Links/2026-08-31 Second.md", status: .pending, createdAt: now))

        await service.tick()

        XCTAssertTrue(launcher.launches.isEmpty, "one at a time — never parallel")
        XCTAssertEqual(ledger.entry(fingerprint: "yt:second")?.status, .pending)
    }

    func testTickSkipsSpawnWhenToggleTurnedOff() async throws {
        try fileNote()
        let appState = makeAppState()
        let (service, ledger, launcher) = makeService(appState: appState)
        enqueue(service)
        appState.settings.update { $0.autoTranscribeYouTube = false }

        await service.tick()

        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertEqual(ledger.entry(fingerprint: fingerprint)?.status, .pending, "parked, not failed")

        appState.settings.update { $0.autoTranscribeYouTube = true }
        await service.tick()
        XCTAssertEqual(launcher.launches.count, 1, "resumes when re-enabled")
    }

    func testTickUsesFolderChangedAfterEnqueue() async throws {
        // Queued under one folder, the setting changes before the spawn: the
        // session runs in the NEW folder — read at dispatch, not at init.
        try fileNote()
        let moved = root.appendingPathComponent("pipeline-repo-moved", isDirectory: true)
        try fm.createDirectory(at: moved, withIntermediateDirectories: true)
        let appState = makeAppState()
        let (service, _, launcher) = makeService(appState: appState)
        enqueue(service)

        appState.settings.update { $0.transcriptPipelineFolder = moved.path }
        await service.tick()

        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertEqual(launcher.launches[0].workingDirectory.path, moved.path)
    }

    func testTickParksQueuedEntryWhileFolderUnavailableAndResumes() async throws {
        try fileNote()
        let appState = makeAppState()
        let (service, ledger, launcher) = makeService(appState: appState)
        enqueue(service)
        XCTAssertEqual(service.skippedDispatchLogCount, 0)

        // The folder goes missing after the capture was queued.
        appState.settings.update { $0.transcriptPipelineFolder = self.missingFolder.path }
        await service.tick()
        await service.tick()
        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertEqual(ledger.entry(fingerprint: fingerprint)?.status, .pending, "parked, not failed")
        XCTAssertNil(appState.transcriptDispatchLastError)
        XCTAssertEqual(service.skippedDispatchLogCount, 1, "one log line, not one per tick")

        // Then the setting is cleared: a new reason, so one more line.
        appState.settings.update { $0.transcriptPipelineFolder = nil }
        await service.tick()
        await service.tick()
        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertEqual(ledger.entry(fingerprint: fingerprint)?.status, .pending)
        XCTAssertEqual(service.skippedDispatchLogCount, 2)

        // The user chooses a folder: the parked entry runs, no restart.
        appState.settings.update { $0.transcriptPipelineFolder = self.pipelineFolder.path }
        await service.tick()
        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertEqual(launcher.launches[0].workingDirectory.path, pipelineFolder.path)
        XCTAssertEqual(ledger.entry(fingerprint: fingerprint)?.status, .dispatched)
    }

    func testTickExpandsTildeInFolderSetting() async throws {
        // A hand-edited settings.json may hold "~/…". "~" itself always
        // exists, so this needs no folder made in the real home directory.
        try fileNote()
        let appState = makeAppState(folder: .path("~"))
        let (service, _, launcher) = makeService(appState: appState)
        enqueue(service)

        await service.tick()

        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertEqual(launcher.launches[0].workingDirectory.path, NSHomeDirectory())
    }

    func testSpawnCompletesWithoutSessionWhenNoteAlreadyHasMarker() async throws {
        try fileNote(body: "content\n\nTranscript: [T](<Media/2026-08-31 Some Video Transcript.md>)\n")
        let appState = makeAppState()
        let (service, ledger, launcher) = makeService(appState: appState)
        enqueue(service)

        await service.tick()

        XCTAssertTrue(launcher.launches.isEmpty, "cron sweep beat us — no session spent")
        XCTAssertEqual(ledger.entry(fingerprint: fingerprint)?.status, .done)
    }

    func testSpawnFailsWhenNoteMissing() async {
        let appState = makeAppState()
        let (service, ledger, launcher) = makeService(appState: appState)
        enqueue(service, path: "Links/Gone.md")

        await service.tick()

        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertEqual(ledger.entry(fingerprint: fingerprint)?.status, .failed)
        XCTAssertNotNil(appState.transcriptDispatchLastError)
    }

    func testSpawnThrowMarksFailed() async throws {
        try fileNote()
        let appState = makeAppState()
        let launcher = FakeTranscriptSessionLauncher()
        launcher.throwOnLaunch = .spawnFailed("claude not found")
        let (service, ledger, _) = makeService(appState: appState, launcher: launcher)
        enqueue(service)

        await service.tick()

        let entry = ledger.entry(fingerprint: fingerprint)
        XCTAssertEqual(entry?.status, .failed)
        XCTAssertTrue(entry?.lastError?.contains("claude not found") == true)
        XCTAssertTrue(appState.transcriptDispatchLastError?.contains("claude not found") == true)
    }

    // MARK: - In-flight resolution

    func testTickMarkerPresentCompletesAndTerminates() async throws {
        try fileNote(body: "content\n\nTRANSCRIPT: [T](<Media/2026-08-31 Some Video Transcript.md>)\n")
        let appState = makeAppState()
        appState.transcriptDispatchLastError = "stale"
        let (service, ledger, launcher) = makeService(appState: appState)
        launcher.running = true
        ledger.append(TranscriptDispatchEntry(
            fingerprint: fingerprint, url: youtubeURL,
            noteRelativePath: "Links/2026-08-31 Some Video.md",
            status: .dispatched, createdAt: now, dispatchedAt: now, attempts: 1))

        await service.tick()

        XCTAssertEqual(ledger.entry(fingerprint: fingerprint)?.status, .done)
        XCTAssertEqual(launcher.terminateCount, 1)
        XCTAssertNil(appState.transcriptDispatchLastError)
    }

    func testTickSessionDiedWithoutMarkerFailsWithDetail() async throws {
        try fileNote()
        let appState = makeAppState()
        let (service, ledger, launcher) = makeService(appState: appState)
        launcher.running = false
        launcher.failureDetail = "claude exited with status 1: no ANTHROPIC session"
        ledger.append(TranscriptDispatchEntry(
            fingerprint: fingerprint, url: youtubeURL,
            noteRelativePath: "Links/2026-08-31 Some Video.md",
            status: .dispatched, createdAt: now, dispatchedAt: now, attempts: 1))

        await service.tick()

        let entry = ledger.entry(fingerprint: fingerprint)
        XCTAssertEqual(entry?.status, .failed)
        XCTAssertTrue(entry?.lastError?.contains("status 1") == true)
    }

    func testTickTimeoutKillsWedgedSession() async throws {
        try fileNote()
        let appState = makeAppState()
        let (service, ledger, launcher) = makeService(appState: appState)
        launcher.running = true
        ledger.append(TranscriptDispatchEntry(
            fingerprint: fingerprint, url: youtubeURL,
            noteRelativePath: "Links/2026-08-31 Some Video.md",
            status: .dispatched, createdAt: now, dispatchedAt: now, attempts: 1))

        await service.tick()
        XCTAssertEqual(ledger.entry(fingerprint: fingerprint)?.status, .dispatched, "within budget — keep waiting")

        clockBox.now = now.addingTimeInterval(TranscriptDispatchService.sessionTimeout + 1)
        await service.tick()

        XCTAssertEqual(launcher.terminateCount, 1)
        XCTAssertEqual(ledger.entry(fingerprint: fingerprint)?.status, .failed)
    }

    // MARK: - Cooldown

    func testCooldownBlocksNextSpawnUntilElapsed() async throws {
        let appState = makeAppState()
        let (service, ledger, launcher) = makeService(appState: appState)
        enqueue(service, path: "Links/Gone.md")
        await service.tick()
        XCTAssertEqual(ledger.entry(fingerprint: fingerprint)?.status, .failed, "primes the cooldown")

        try fileNote(base: "2026-08-31 Next")
        ledger.append(TranscriptDispatchEntry(
            fingerprint: "yt:next", url: "u", noteRelativePath: "Links/2026-08-31 Next.md",
            status: .pending, createdAt: now))

        await service.tick()
        XCTAssertTrue(launcher.launches.isEmpty, "cooldown holds")

        clockBox.now = now.addingTimeInterval(TranscriptDispatchService.failureCooldown + 1)
        await service.tick()
        XCTAssertEqual(launcher.launches.count, 1, "cooldown elapsed")
    }

    // MARK: - Reconciliation & retry

    func testReconcileResolvesDispatchedEntries() async throws {
        try fileNote(base: "2026-08-31 Finished", body: "x\nTranscript: https://drive.google.com/file/d/1/view\n")
        try fileNote(base: "2026-08-31 Interrupted")
        let appState = makeAppState()
        let (service, ledger, _) = makeService(appState: appState)
        ledger.append(TranscriptDispatchEntry(
            fingerprint: "yt:finished", url: "u", noteRelativePath: "Links/2026-08-31 Finished.md",
            status: .dispatched, createdAt: now, dispatchedAt: now))
        ledger.append(TranscriptDispatchEntry(
            fingerprint: "yt:interrupted", url: "u", noteRelativePath: "Links/2026-08-31 Interrupted.md",
            status: .dispatched, createdAt: now, dispatchedAt: now))
        ledger.append(TranscriptDispatchEntry(
            fingerprint: "yt:waiting", url: "u", noteRelativePath: "Links/W.md",
            status: .pending, createdAt: now))

        await service.reconcile()

        XCTAssertEqual(ledger.entry(fingerprint: "yt:finished")?.status, .done)
        XCTAssertEqual(ledger.entry(fingerprint: "yt:interrupted")?.status, .failed)
        XCTAssertTrue(ledger.entry(fingerprint: "yt:interrupted")?.lastError?.contains("restart") == true)
        XCTAssertEqual(ledger.entry(fingerprint: "yt:waiting")?.status, .pending, "pending untouched")
    }

    func testRetryFailedResetsAndClearsError() async throws {
        let appState = makeAppState()
        let (service, ledger, launcher) = makeService(appState: appState)
        enqueue(service, path: "Links/Gone.md")
        await service.tick()
        XCTAssertEqual(ledger.entry(fingerprint: fingerprint)?.status, .failed)

        try fileNote(base: "Gone")
        service.retryFailed()
        XCTAssertNil(appState.transcriptDispatchLastError)
        XCTAssertEqual(ledger.entry(fingerprint: fingerprint)?.status, .pending)

        await service.tick()
        XCTAssertEqual(launcher.launches.count, 1, "retry cleared the cooldown too")
    }

    // MARK: - Pure contract pieces

    func testPromptTemplateLocked() {
        let prompt = TranscriptDispatch.prompt(
            url: "https://youtu.be/JGB-D1xd400",
            noteAbsolutePath: "/Volumes/X/Second Brain/Rapture Inbox/Links/2026-08-31 Talk.md",
            transcriptAbsolutePath: "/Volumes/X/Second Brain/Rapture Inbox/Links/Media/2026-08-31 Talk Transcript.md",
            transcriptLine: TranscriptDispatch.transcriptLine(transcriptFilename: "2026-08-31 Talk Transcript.md"))
        XCTAssertEqual(prompt, """
        Run the "YouTube URL → Drive Transcript" pipeline defined in AGENTS.md on this URL: https://youtu.be/JGB-D1xd400

        Two overrides for this run: skip the ack reply and do not reply anywhere else, and do NOT create a Google Doc — write the full cleaned-up transcript as a Markdown file at /Volumes/X/Second Brain/Rapture Inbox/Links/Media/2026-08-31 Talk Transcript.md instead.

        After that file exists, append exactly this one line to the end of the Markdown note at /Volumes/X/Second Brain/Rapture Inbox/Links/2026-08-31 Talk.md:

        Transcript: [2026-08-31 Talk Transcript](<Media/2026-08-31 Talk Transcript.md>)

        Change nothing else in the note. If the pipeline fails, write no transcript file and leave the note untouched.
        """)
    }

    func testPipelineFolderURLFromSetting() {
        XCTAssertNil(TranscriptDispatch.pipelineFolderURL(fromSetting: nil))
        XCTAssertNil(TranscriptDispatch.pipelineFolderURL(fromSetting: ""))
        XCTAssertNil(TranscriptDispatch.pipelineFolderURL(fromSetting: "  \n"))
        XCTAssertEqual(
            TranscriptDispatch.pipelineFolderURL(fromSetting: "/tmp/pipeline")?.path,
            "/tmp/pipeline")
        XCTAssertEqual(
            TranscriptDispatch.pipelineFolderURL(fromSetting: "  /tmp/pipeline \n")?.path,
            "/tmp/pipeline", "surrounding whitespace from a hand edit is trimmed")
        XCTAssertEqual(
            TranscriptDispatch.pipelineFolderURL(fromSetting: "~/some/pipeline")?.path,
            NSHomeDirectory() + "/some/pipeline", "a leading ~ is expanded")
        XCTAssertEqual(
            TranscriptDispatch.pipelineFolderURL(fromSetting: "~")?.path,
            NSHomeDirectory())
    }

    func testPipelineFolderStatus() throws {
        XCTAssertEqual(TranscriptDispatch.pipelineFolderStatus(setting: nil), .notSet)
        XCTAssertEqual(TranscriptDispatch.pipelineFolderStatus(setting: " "), .notSet)

        guard case .ready(let ready) = TranscriptDispatch.pipelineFolderStatus(setting: pipelineFolder.path) else {
            return XCTFail("an existing folder is ready")
        }
        XCTAssertEqual(ready.path, pipelineFolder.path)

        guard case .missing(let missing) = TranscriptDispatch.pipelineFolderStatus(setting: missingFolder.path) else {
            return XCTFail("a path with nothing there is missing")
        }
        XCTAssertEqual(missing.path, missingFolder.path)

        let file = root.appendingPathComponent("a-file.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        guard case .missing = TranscriptDispatch.pipelineFolderStatus(setting: file.path) else {
            return XCTFail("a file is not a folder a session can run in")
        }
    }

    func testSkipReasonNamesTheProblem() {
        XCTAssertNil(TranscriptDispatch.PipelineFolderStatus.ready(pipelineFolder).skipReason)
        XCTAssertEqual(
            TranscriptDispatch.PipelineFolderStatus.notSet.skipReason,
            "the pipeline folder is not set")
        XCTAssertEqual(
            TranscriptDispatch.PipelineFolderStatus.missing(URL(fileURLWithPath: "/gone/repo")).skipReason,
            "the pipeline folder was not found at /gone/repo")
    }

    func testTranscriptPathAndLineHelpers() {
        XCTAssertEqual(
            TranscriptDispatch.transcriptRelativePath(forNoteRelativePath: "Links/2026-08-31 Talk.md"),
            "Links/Media/2026-08-31 Talk Transcript.md")
        XCTAssertEqual(
            TranscriptDispatch.transcriptRelativePath(forNoteRelativePath: "Loose.md"),
            "Media/Loose Transcript.md")
        XCTAssertEqual(
            TranscriptDispatch.transcriptLine(transcriptFilename: "2026-08-31 Talk Transcript.md"),
            "Transcript: [2026-08-31 Talk Transcript](<Media/2026-08-31 Talk Transcript.md>)")
    }

    func testContainsTranscriptMarker() {
        XCTAssertTrue(TranscriptDispatch.containsTranscriptMarker("body\nTranscript: [T](<Media/T Transcript.md>)\n"))
        XCTAssertTrue(TranscriptDispatch.containsTranscriptMarker("  transcript: hand-added lowercase"))
        // Legacy Drive-pipeline output still counts as satisfied.
        XCTAssertTrue(TranscriptDispatch.containsTranscriptMarker("see https://docs.google.com/document/d/x"))
        XCTAssertTrue(TranscriptDispatch.containsTranscriptMarker("https://drive.google.com/file/d/1/view"))
        XCTAssertFalse(TranscriptDispatch.containsTranscriptMarker("mentions a transcript: mid-sentence? no — line must start with it"))
        XCTAssertFalse(TranscriptDispatch.containsTranscriptMarker("https://www.youtube.com/watch?v=x plus text"))
        XCTAssertFalse(TranscriptDispatch.containsTranscriptMarker(""))
    }
}
