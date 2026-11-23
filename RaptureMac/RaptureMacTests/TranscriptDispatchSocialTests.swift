import XCTest
@testable import Rapture

/// The social-post side of the transcript dispatch: the second prompt (locked
/// by an exact-string test, like the YouTube one), the chooser, the kind rule,
/// and the dispatcher's two independent toggles. Same fixtures shape as
/// `TranscriptDispatchServiceTests`: fake launcher, temp dirs, `tick()`.
@MainActor
final class TranscriptDispatchSocialTests: XCTestCase {

    private let fm = FileManager.default
    private var root: URL!
    private var output: URL!
    private var support: URL!
    private var pipelineFolder: URL!

    private let facebookURL = "https://www.facebook.com/reel/1234567890/"
    private let facebookFingerprint = "url:https://www.facebook.com/reel/1234567890"
    private let xURL = "https://x.com/someone/status/1234567890"
    private let xFingerprint = "url:https://x.com/someone/status/1234567890"
    private let youtubeURL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    private let youtubeFingerprint = "yt:dQw4w9WgXcQ"

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("dispatch-social-\(UUID().uuidString)", isDirectory: true)
        output = root.appendingPathComponent("Rapture Notes", isDirectory: true)
        support = root.appendingPathComponent("Support", isDirectory: true)
        pipelineFolder = root.appendingPathComponent("pipeline-repo", isDirectory: true)
        try fm.createDirectory(at: output.appendingPathComponent("Links", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        try fm.createDirectory(at: pipelineFolder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
    }

    // MARK: - Fixtures

    private func makeAppState(youtube: Bool = true, social: Bool = true) -> AppState {
        let appState = AppState(supportDirectory: support)
        appState.settings.update {
            $0.outputFolder = output
            $0.paused = false
            $0.triageMode = .full
            $0.linkEnrichmentEnabled = true
            $0.autoTranscribeYouTube = youtube
            $0.autoTranscribeSocialVideos = social
            $0.transcriptPipelineFolder = pipelineFolder.path
        }
        return appState
    }

    private func makeService(appState: AppState) -> (TranscriptDispatchService, TranscriptDispatchLedger, FakeTranscriptSessionLauncher) {
        let launcher = FakeTranscriptSessionLauncher()
        let ledger = TranscriptDispatchLedger(stateStore: appState.state)
        return (TranscriptDispatchService(appState: appState, ledger: ledger, launcher: launcher), ledger, launcher)
    }

    @discardableResult
    private func fileNote(base: String) throws -> URL {
        let url = output.appendingPathComponent("Links/\(base).md")
        try "content".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - The prompts

    private let note = "/Volumes/X/Notes/Links/2026-11-23 Bakery hours.md"
    private let transcript = "/Volumes/X/Notes/Links/Media/2026-11-23 Bakery hours Transcript.md"
    private var line: String {
        TranscriptDispatch.transcriptLine(transcriptFilename: "2026-11-23 Bakery hours Transcript.md")
    }

    func testSocialPostPromptTemplateLocked() {
        let prompt = TranscriptDispatch.socialPostPrompt(
            url: "https://www.facebook.com/reel/1234567890/",
            noteAbsolutePath: note, transcriptAbsolutePath: transcript, transcriptLine: line)
        XCTAssertEqual(prompt, """
        Run the "Social Post URL → Drive Transcript" pipeline defined in AGENTS.md on this URL: https://www.facebook.com/reel/1234567890/

        Two overrides for this run: skip the ack reply and do not reply anywhere else, and do NOT create a Google Doc — write the full cleaned-up transcript as a Markdown file at /Volumes/X/Notes/Links/Media/2026-11-23 Bakery hours Transcript.md instead.

        After that file exists, append exactly this one line to the end of the Markdown note at /Volumes/X/Notes/Links/2026-11-23 Bakery hours.md:

        Transcript: [2026-11-23 Bakery hours Transcript](<Media/2026-11-23 Bakery hours Transcript.md>)

        Change nothing else in the note. If the pipeline fails, write no transcript file and leave the note untouched.
        """)
    }

    func testYouTubePromptIsUnchanged() {
        let prompt = TranscriptDispatch.prompt(
            url: "https://youtu.be/JGB-D1xd400",
            noteAbsolutePath: note, transcriptAbsolutePath: transcript, transcriptLine: line)
        XCTAssertEqual(prompt, """
        Run the "YouTube URL → Drive Transcript" pipeline defined in AGENTS.md on this URL: https://youtu.be/JGB-D1xd400

        Two overrides for this run: skip the ack reply and do not reply anywhere else, and do NOT create a Google Doc — write the full cleaned-up transcript as a Markdown file at /Volumes/X/Notes/Links/Media/2026-11-23 Bakery hours Transcript.md instead.

        After that file exists, append exactly this one line to the end of the Markdown note at /Volumes/X/Notes/Links/2026-11-23 Bakery hours.md:

        Transcript: [2026-11-23 Bakery hours Transcript](<Media/2026-11-23 Bakery hours Transcript.md>)

        Change nothing else in the note. If the pipeline fails, write no transcript file and leave the note untouched.
        """)
    }

    func testThePromptsDifferOnlyInTheFirstLine() {
        let url = "https://x.com/someone/status/1"
        let social = TranscriptDispatch.socialPostPrompt(url: url, noteAbsolutePath: note, transcriptAbsolutePath: transcript, transcriptLine: line)
        let youTube = TranscriptDispatch.prompt(url: url, noteAbsolutePath: note, transcriptAbsolutePath: transcript, transcriptLine: line)
        XCTAssertNotEqual(social, youTube)
        let socialLines = social.split(separator: "\n", omittingEmptySubsequences: false)
        let youTubeLines = youTube.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(socialLines.count, youTubeLines.count)
        XCTAssertNotEqual(socialLines.first, youTubeLines.first)
        XCTAssertEqual(Array(socialLines.dropFirst()), Array(youTubeLines.dropFirst()))
    }

    func testChooserPicksTheSocialPromptForSocialHosts() {
        for url in [
            "https://www.facebook.com/reel/1/", "https://fb.watch/abc/", "https://m.facebook.com/somepage/videos/1",
            "https://x.com/someone/status/1", "https://twitter.com/someone/status/1",
            "https://www.instagram.com/reel/AbC/", "https://www.threads.net/@someone/post/B"
        ] {
            let prompt = TranscriptDispatch.pipelinePrompt(forURL: url, noteAbsolutePath: note, transcriptAbsolutePath: transcript, transcriptLine: line)
            XCTAssertEqual(
                prompt,
                TranscriptDispatch.socialPostPrompt(url: url, noteAbsolutePath: note, transcriptAbsolutePath: transcript, transcriptLine: line),
                url)
            XCTAssertTrue(prompt.hasPrefix("Run the \"Social Post URL → Drive Transcript\" pipeline"), url)
        }
    }

    func testChooserPicksTheYouTubePromptForYouTubeAndEverythingElse() {
        for url in [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "https://youtu.be/dQw4w9WgXcQ",
            "https://notfacebook.com/post", "https://facebook.com.evil.example/x",
            "", "not a url", "https://example.com/story"
        ] {
            let prompt = TranscriptDispatch.pipelinePrompt(forURL: url, noteAbsolutePath: note, transcriptAbsolutePath: transcript, transcriptLine: line)
            XCTAssertEqual(
                prompt,
                TranscriptDispatch.prompt(url: url, noteAbsolutePath: note, transcriptAbsolutePath: transcript, transcriptLine: line),
                url)
        }
    }

    // MARK: - Kind

    func testKindByFingerprintAndHost() {
        XCTAssertEqual(TranscriptDispatch.kind(fingerprint: youtubeFingerprint, url: youtubeURL), .youtube)
        XCTAssertEqual(TranscriptDispatch.kind(fingerprint: youtubeFingerprint, url: ""), .youtube, "yt: needs no URL")
        XCTAssertEqual(TranscriptDispatch.kind(fingerprint: facebookFingerprint, url: facebookURL), .socialVideo)
        XCTAssertEqual(TranscriptDispatch.kind(fingerprint: xFingerprint, url: xURL), .socialVideo)
        XCTAssertEqual(TranscriptDispatch.kind(fingerprint: "url:https://fb.watch/abc", url: "https://fb.watch/abc/"), .socialVideo)
    }

    func testKindIsNilForEverythingTheDispatcherMustIgnore() {
        XCTAssertNil(TranscriptDispatch.kind(fingerprint: "url:https://www.instagram.com/reel/AbC", url: "https://www.instagram.com/reel/AbC/"))
        XCTAssertNil(TranscriptDispatch.kind(fingerprint: "url:https://www.threads.net/@a/post/B", url: "https://www.threads.net/@a/post/B"))
        XCTAssertNil(TranscriptDispatch.kind(fingerprint: "url:https://example.com/post", url: "https://example.com/post"))
        XCTAssertNil(TranscriptDispatch.kind(fingerprint: "url:https://notfacebook.com/post", url: "https://notfacebook.com/post"))
        XCTAssertNil(TranscriptDispatch.kind(fingerprint: facebookFingerprint, url: ""))
        XCTAssertNil(TranscriptDispatch.kind(fingerprint: "other:thing", url: facebookURL))
    }

    // MARK: - Enqueue

    func testCaptureEnrichedQueuesAFacebookVideo() {
        let (service, ledger, _) = makeService(appState: makeAppState())
        service.captureEnriched(fingerprint: facebookFingerprint, url: facebookURL, noteRelativePath: "Links/2026-11-23 Bakery hours.md")
        let entry = ledger.entry(fingerprint: facebookFingerprint)
        XCTAssertEqual(entry?.status, .pending)
        XCTAssertEqual(entry?.url, facebookURL)
        XCTAssertEqual(entry?.noteRelativePath, "Links/2026-11-23 Bakery hours.md")
    }

    func testCaptureEnrichedIgnoresWhenTheSocialToggleIsOff() {
        let (service, ledger, _) = makeService(appState: makeAppState(social: false))
        service.captureEnriched(fingerprint: facebookFingerprint, url: facebookURL, noteRelativePath: "Links/A.md")
        service.captureEnriched(fingerprint: xFingerprint, url: xURL, noteRelativePath: "Links/B.md")
        XCTAssertTrue(ledger.records.isEmpty)
        XCTAssertEqual(service.skippedDispatchLogCount, 0, "toggle off is the user's choice, not a skipped dispatch")
    }

    func testTheTwoTogglesAreIndependent() {
        let (offYouTube, ledgerA, _) = makeService(appState: makeAppState(youtube: false, social: true))
        offYouTube.captureEnriched(fingerprint: youtubeFingerprint, url: youtubeURL, noteRelativePath: "Links/A.md")
        offYouTube.captureEnriched(fingerprint: facebookFingerprint, url: facebookURL, noteRelativePath: "Links/B.md")
        XCTAssertNil(ledgerA.entry(fingerprint: youtubeFingerprint))
        XCTAssertNotNil(ledgerA.entry(fingerprint: facebookFingerprint))
    }

    func testTheYouTubeToggleStaysIndependentOfTheSocialToggle() throws {
        let appState = makeAppState(youtube: true, social: false)
        let (service, ledger, _) = makeService(appState: appState)
        service.captureEnriched(fingerprint: youtubeFingerprint, url: youtubeURL, noteRelativePath: "Links/A.md")
        service.captureEnriched(fingerprint: xFingerprint, url: xURL, noteRelativePath: "Links/B.md")
        XCTAssertNotNil(ledger.entry(fingerprint: youtubeFingerprint))
        XCTAssertNil(ledger.entry(fingerprint: xFingerprint))
    }

    func testCaptureEnrichedIgnoresInstagramThreadsAndArticles() {
        let (service, ledger, _) = makeService(appState: makeAppState())
        service.captureEnriched(fingerprint: "url:https://www.instagram.com/reel/AbC", url: "https://www.instagram.com/reel/AbC/", noteRelativePath: "Links/A.md")
        service.captureEnriched(fingerprint: "url:https://www.threads.net/@a/post/B", url: "https://www.threads.net/@a/post/B", noteRelativePath: "Links/B.md")
        service.captureEnriched(fingerprint: "url:https://example.com/post", url: "https://example.com/post", noteRelativePath: "Links/C.md")
        XCTAssertTrue(ledger.records.isEmpty)
    }

    func testSocialQueueNeedsThePipelineFolderLikeYouTube() {
        let appState = makeAppState()
        appState.settings.update { $0.transcriptPipelineFolder = nil }
        let (service, ledger, _) = makeService(appState: appState)
        service.captureEnriched(fingerprint: facebookFingerprint, url: facebookURL, noteRelativePath: "Links/A.md")
        XCTAssertTrue(ledger.records.isEmpty)
        XCTAssertEqual(service.skippedDispatchLogCount, 1)
    }

    // MARK: - Spawn

    func testTickSpawnsASocialEntryWithTheSocialPrompt() async throws {
        try fileNote(base: "2026-11-23 Bakery hours")
        let (service, ledger, launcher) = makeService(appState: makeAppState())
        service.captureEnriched(fingerprint: facebookFingerprint, url: facebookURL, noteRelativePath: "Links/2026-11-23 Bakery hours.md")

        await service.tick()

        XCTAssertEqual(launcher.launches.count, 1)
        let prompt = launcher.launches[0].prompt
        XCTAssertEqual(prompt, TranscriptDispatch.socialPostPrompt(
            url: facebookURL,
            noteAbsolutePath: output.appendingPathComponent("Links/2026-11-23 Bakery hours.md").path,
            transcriptAbsolutePath: output.appendingPathComponent("Links/Media/2026-11-23 Bakery hours Transcript.md").path,
            transcriptLine: "Transcript: [2026-11-23 Bakery hours Transcript](<Media/2026-11-23 Bakery hours Transcript.md>)"))
        XCTAssertEqual(ledger.entry(fingerprint: facebookFingerprint)?.status, .dispatched)
    }

    func testTickStillSpawnsAYouTubeEntryWithTheYouTubePrompt() async throws {
        try fileNote(base: "2026-11-23 Talk")
        let (service, _, launcher) = makeService(appState: makeAppState())
        service.captureEnriched(fingerprint: youtubeFingerprint, url: youtubeURL, noteRelativePath: "Links/2026-11-23 Talk.md")

        await service.tick()

        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertTrue(launcher.launches[0].prompt.hasPrefix("Run the \"YouTube URL → Drive Transcript\" pipeline"))
    }

    func testAParkedEntryDoesNotBlockOneWhoseToggleIsOn() async throws {
        try fileNote(base: "2026-11-23 Talk")
        try fileNote(base: "2026-11-23 Bakery hours")
        let appState = makeAppState()
        let (service, ledger, launcher) = makeService(appState: appState)
        service.captureEnriched(fingerprint: youtubeFingerprint, url: youtubeURL, noteRelativePath: "Links/2026-11-23 Talk.md")
        service.captureEnriched(fingerprint: facebookFingerprint, url: facebookURL, noteRelativePath: "Links/2026-11-23 Bakery hours.md")

        // The YouTube entry is older, but its toggle goes off before the tick.
        appState.settings.update { $0.autoTranscribeYouTube = false }
        await service.tick()

        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertTrue(launcher.launches[0].prompt.contains(facebookURL))
        XCTAssertEqual(ledger.entry(fingerprint: youtubeFingerprint)?.status, .pending, "parked, not failed")
    }

    func testTickSkipsSpawnWhenTheSocialToggleIsTurnedOffAndResumes() async throws {
        try fileNote(base: "2026-11-23 Bakery hours")
        let appState = makeAppState()
        let (service, ledger, launcher) = makeService(appState: appState)
        service.captureEnriched(fingerprint: xFingerprint, url: xURL, noteRelativePath: "Links/2026-11-23 Bakery hours.md")
        appState.settings.update { $0.autoTranscribeSocialVideos = false }

        await service.tick()
        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertEqual(ledger.entry(fingerprint: xFingerprint)?.status, .pending, "parked, not failed")

        appState.settings.update { $0.autoTranscribeSocialVideos = true }
        await service.tick()
        XCTAssertEqual(launcher.launches.count, 1, "resumes when re-enabled")
    }
}
