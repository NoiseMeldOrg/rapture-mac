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
    private var agenticRepo: URL!
    private var clockBox: ClockBox!

    private let youtubeURL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    private let fingerprint = "yt:dQw4w9WgXcQ"

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("dispatch-\(UUID().uuidString)", isDirectory: true)
        output = root.appendingPathComponent("Rapture Notes", isDirectory: true)
        support = root.appendingPathComponent("Support", isDirectory: true)
        agenticRepo = root.appendingPathComponent("agentic-os-mirror", isDirectory: true)
        try fm.createDirectory(at: output.appendingPathComponent("Links", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        try fm.createDirectory(at: agenticRepo, withIntermediateDirectories: true)
        clockBox = ClockBox(Date(timeIntervalSince1970: 1_800_000_000))
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
    }

    // MARK: - Fixtures

    private var now: Date { clockBox.now }

    private func makeAppState(autoTranscribe: Bool = true) -> AppState {
        let appState = AppState(supportDirectory: support)
        appState.settings.update {
            $0.outputFolder = output
            $0.paused = false
            $0.triageMode = .full
            $0.linkEnrichmentEnabled = true
            $0.autoTranscribeYouTube = autoTranscribe
        }
        return appState
    }

    private func makeService(
        appState: AppState,
        launcher: FakeTranscriptSessionLauncher? = nil,
        agenticRepo: URL? = nil
    ) -> (TranscriptDispatchService, TranscriptDispatchLedger, FakeTranscriptSessionLauncher) {
        let launcher = launcher ?? FakeTranscriptSessionLauncher()
        let ledger = TranscriptDispatchLedger(stateStore: appState.state, clock: { [clockBox] in clockBox?.now ?? Date() })
        let service = TranscriptDispatchService(
            appState: appState,
            ledger: ledger,
            launcher: launcher,
            agenticRepo: agenticRepo ?? self.agenticRepo,
            clock: { [clockBox] in clockBox?.now ?? Date() }
        )
        return (service, ledger, launcher)
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

    func testCaptureEnrichedIgnoresWhenAgenticRepoMissing() {
        let appState = makeAppState()
        let missing = root.appendingPathComponent("nowhere", isDirectory: true)
        let (service, ledger, _) = makeService(appState: appState, agenticRepo: missing)
        enqueue(service)
        XCTAssertTrue(ledger.records.isEmpty)
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
        XCTAssertEqual(launcher.launches[0].workingDirectory, agenticRepo)
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
