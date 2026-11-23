import XCTest
@testable import Rapture

/// `LinkEnrichmentService` with Facebook, Instagram, Threads and X links:
/// routing to the social fetcher, the artifact and note it writes, the
/// content-class give-up on a login wall, and the transcript hand-off rules
/// (Facebook and X videos only). The real dispatcher is wired in at the end.
/// Fake fetcher, temp dirs, no network, no real sleeps.
@MainActor
final class SocialPostEnrichmentTests: XCTestCase {

    private let fm = FileManager.default
    private var root: URL!
    private var output: URL!
    private var support: URL!
    private var pipelineFolder: URL!

    private let facebookReel = "https://www.facebook.com/reel/1234567890/"
    private let facebookPost = "https://www.facebook.com/somepage/posts/55"
    private let instagramReel = "https://www.instagram.com/reel/AbC123/"
    private let threadsPost = "https://www.threads.net/@someone/post/B1"
    private let xPost = "https://x.com/someone/status/1234567890"

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("social-enrich-\(UUID().uuidString)", isDirectory: true)
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

    private func makeAppState(socialToggle: Bool = true) -> AppState {
        let appState = AppState(supportDirectory: support)
        appState.settings.update {
            $0.outputFolder = output
            $0.paused = false
            $0.triageMode = .full
            $0.linkEnrichmentEnabled = true
            $0.autoTranscribeSocialVideos = socialToggle
            $0.transcriptPipelineFolder = pipelineFolder.path
        }
        return appState
    }

    private func makeService(
        appState: AppState,
        fetcher: FakeLinkFetcher,
        dispatch: (any TranscriptDispatching)? = nil
    ) -> LinkEnrichmentService {
        LinkEnrichmentService(
            appState: appState,
            fetcher: fetcher,
            ledger: EnrichedLinkLedger(stateStore: appState.state),
            triageLedger: TriageLedger(stateStore: appState.state),
            transcriptDispatch: dispatch,
            retrySpacing: [0, 0],
            sleeper: { _ in }
        )
    }

    private func content(title: String? = "Bakery hours change", body: String = "Bakery hours change on Monday.", isVideo: Bool) -> FakeLinkFetcher.Behavior {
        .content(FetchedLinkContent(title: title, bodyMarkdown: body, isVideo: isVideo))
    }

    @discardableResult
    private func fileLinkNote(base: String = "2026-07-13 facebook.com", media: String) throws -> URL {
        let url = output.appendingPathComponent("Links/\(base).md")
        let text = """
        ---
        captured: 2026-07-13T12:00:00Z
        source: rapture-mac
        type: article-link
        raw_media: \(media)
        ---

        \(media)
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func echo(_ media: String) -> LinkNoteEcho {
        // Midday UTC, so the local calendar day is 2026-07-13 in every CI zone
        // (the LinkEnrichmentServiceTests rationale).
        LinkNoteEcho(type: .articleLink, rawMedia: media, capturedAt: Date(timeIntervalSince1970: 1_783_944_000))
    }

    // MARK: - Routing and output

    func testFacebookLinkGoesToTheSocialFetcherNotTheArticleFetcher() async throws {
        let note = try fileLinkNote(media: facebookReel)
        let fetcher = FakeLinkFetcher(behavior: content(isVideo: true))
        let service = makeService(appState: makeAppState(), fetcher: fetcher)

        service.noteFiled(noteURL: note, in: output, echo: echo(facebookReel))
        await service.awaitIdle()

        XCTAssertEqual(fetcher.socialCalls.map(\.url.absoluteString), [facebookReel])
        XCTAssertEqual(fetcher.socialCalls.map(\.platform), [.facebook])
        XCTAssertTrue(fetcher.articleCalls.isEmpty)
        XCTAssertTrue(fetcher.youTubeCalls.isEmpty)
    }

    func testEachSocialHostRoutesToItsPlatform() async throws {
        let cases: [(String, SocialPost.Platform)] = [
            (facebookPost, .facebook), (instagramReel, .instagram), (threadsPost, .threads), (xPost, .x),
            ("https://twitter.com/someone/status/9", .x), ("https://fb.watch/abc/", .facebook),
            ("https://m.facebook.com/somepage/posts/1", .facebook)
        ]
        for (index, entry) in cases.enumerated() {
            let note = try fileLinkNote(base: "2026-07-13 case\(index)", media: entry.0)
            let fetcher = FakeLinkFetcher(behavior: content(isVideo: false))
            let service = makeService(appState: makeAppState(), fetcher: fetcher)
            service.noteFiled(noteURL: note, in: output, echo: echo(entry.0))
            await service.awaitIdle()
            XCTAssertEqual(fetcher.socialCalls.map(\.platform), [entry.1], entry.0)
            XCTAssertTrue(fetcher.articleCalls.isEmpty, entry.0)
        }
    }

    func testLookAlikeHostsAndPlainArticlesKeepUsingTheArticleFetcher() async throws {
        for (index, media) in ["https://notfacebook.com/post", "https://facebook.com.evil.example/x", "https://example.com/story"].enumerated() {
            let note = try fileLinkNote(base: "2026-07-13 plain\(index)", media: media)
            let fetcher = FakeLinkFetcher(behavior: content(isVideo: false))
            let service = makeService(appState: makeAppState(), fetcher: fetcher)
            service.noteFiled(noteURL: note, in: output, echo: echo(media))
            await service.awaitIdle()
            XCTAssertEqual(fetcher.articleCalls.map(\.absoluteString), [media])
            XCTAssertTrue(fetcher.socialCalls.isEmpty, media)
        }
    }

    func testSocialPostWritesTheSameKindOfArtifactAsAnArticle() async throws {
        let note = try fileLinkNote(media: facebookPost)
        let appState = makeAppState()
        let fetcher = FakeLinkFetcher(behavior: content(title: "Bakery hours change", body: "Bakery hours change on Monday.\n\nSecond paragraph.", isVideo: false))
        let service = makeService(appState: appState, fetcher: fetcher)

        service.noteFiled(noteURL: note, in: output, echo: echo(facebookPost))
        await service.awaitIdle()

        let renamed = output.appendingPathComponent("Links/2026-07-13 Bakery hours change.md")
        XCTAssertTrue(fm.fileExists(atPath: renamed.path), "note renamed to the post's first line")
        let artifact = output.appendingPathComponent("Links/Media/2026-07-13 Bakery hours change.md")
        let artifactText = try String(contentsOf: artifact, encoding: .utf8)
        XCTAssertTrue(artifactText.contains("source: \(facebookPost)"))
        XCTAssertTrue(artifactText.contains("capture: ../2026-07-13 Bakery hours change.md"))
        XCTAssertTrue(artifactText.contains("type: article-extract"))
        XCTAssertTrue(artifactText.hasSuffix("Bakery hours change on Monday.\n\nSecond paragraph.\n"))
        let noteText = try String(contentsOf: renamed, encoding: .utf8)
        XCTAssertTrue(noteText.contains("Media:\n- [Bakery hours change](<Media/2026-07-13 Bakery hours change.md>)"))
        XCTAssertEqual(
            EnrichedLinkLedger(stateStore: appState.state).entry(fingerprint: "url:\(facebookPost)")?.title,
            "Bakery hours change")
        XCTAssertNil(appState.enrichmentLastError)
    }

    func testSocialPostWithoutATitleKeepsTheNoteNameAndUsesAPostFallbackName() async throws {
        let note = try fileLinkNote(media: threadsPost)
        let fetcher = FakeLinkFetcher(behavior: content(title: nil, body: "Words.", isVideo: false))
        let service = makeService(appState: makeAppState(), fetcher: fetcher)

        service.noteFiled(noteURL: note, in: output, echo: echo(threadsPost))
        await service.awaitIdle()

        XCTAssertTrue(fm.fileExists(atPath: note.path), "no title, no rename")
        XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent("Links/Media/2026-07-13 Social Post.md").path))
    }

    // MARK: - Content-class and transport failures

    func testLoginWallGivesUpAtOnceWithNoRetryAndLeavesTheNote() async throws {
        let note = try fileLinkNote(media: facebookReel)
        let before = try String(contentsOf: note, encoding: .utf8)
        let appState = makeAppState()
        let spy = SpyTranscriptDispatching()
        let fetcher = FakeLinkFetcher(behavior: .error(.unusableContent))
        let service = makeService(appState: appState, fetcher: fetcher, dispatch: spy)

        service.noteFiled(noteURL: note, in: output, echo: echo(facebookReel))
        await service.awaitIdle()

        XCTAssertEqual(fetcher.totalCalls, 1, "content-class: no retry")
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), before, "note stays as filed")
        XCTAssertFalse(fm.fileExists(atPath: output.appendingPathComponent("Links/Media").path))
        XCTAssertTrue(spy.calls.isEmpty)
        XCTAssertEqual(appState.enrichmentLastError, "Couldn't read the last social post link (it may be private or removed). The note filed normally.")
        XCTAssertNil(appState.lastError, "never the menu-bar error surface")
    }

    func testTransportErrorOnASocialPostUsesTheExistingRetrySchedule() async throws {
        let note = try fileLinkNote(media: xPost)
        let fetcher = FakeLinkFetcher(behavior: .error(.timeout))
        let service = makeService(appState: makeAppState(), fetcher: fetcher)

        service.noteFiled(noteURL: note, in: output, echo: echo(xPost))
        await service.awaitIdle()

        XCTAssertEqual(fetcher.totalCalls, LinkEnrichmentService.maxAttempts)
    }

    func testBlockedURLOnASocialLinkIsContentClass() async throws {
        let note = try fileLinkNote(media: facebookPost)
        let fetcher = FakeLinkFetcher(behavior: .error(.blockedURL))
        let service = makeService(appState: makeAppState(), fetcher: fetcher)

        service.noteFiled(noteURL: note, in: output, echo: echo(facebookPost))
        await service.awaitIdle()

        XCTAssertEqual(fetcher.totalCalls, 1)
    }

    // MARK: - The transcript hand-off

    func testFacebookVideoIsEnrichedAndDispatched() async throws {
        let note = try fileLinkNote(media: facebookReel)
        let spy = SpyTranscriptDispatching()
        let service = makeService(appState: makeAppState(), fetcher: FakeLinkFetcher(behavior: content(isVideo: true)), dispatch: spy)

        service.noteFiled(noteURL: note, in: output, echo: echo(facebookReel))
        await service.awaitIdle()

        XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent("Links/Media/2026-07-13 Bakery hours change.md").path), "enriched")
        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls[0].fingerprint, "url:\(facebookReel.dropLast())", "the normalized URL (trailing slash dropped)")
        XCTAssertEqual(spy.calls[0].url, facebookReel)
        XCTAssertEqual(spy.calls[0].noteRelativePath, "Links/2026-07-13 Bakery hours change.md", "the post-rename path")
    }

    func testXVideoIsDispatched() async throws {
        let note = try fileLinkNote(base: "2026-07-13 x.com", media: xPost)
        let spy = SpyTranscriptDispatching()
        let service = makeService(appState: makeAppState(), fetcher: FakeLinkFetcher(behavior: content(isVideo: true)), dispatch: spy)

        service.noteFiled(noteURL: note, in: output, echo: echo(xPost))
        await service.awaitIdle()

        XCTAssertEqual(spy.calls.map(\.url), [xPost])
    }

    func testFacebookAndXPostsWithoutAVideoAreEnrichedButNotDispatched() async throws {
        for (index, media) in [facebookPost, xPost].enumerated() {
            let note = try fileLinkNote(base: "2026-07-13 text\(index)", media: media)
            let spy = SpyTranscriptDispatching()
            let service = makeService(appState: makeAppState(), fetcher: FakeLinkFetcher(behavior: content(title: "Text post \(index)", isVideo: false)), dispatch: spy)

            service.noteFiled(noteURL: note, in: output, echo: echo(media))
            await service.awaitIdle()

            XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent("Links/Media/2026-07-13 Text post \(index).md").path), "still enriched")
            XCTAssertTrue(spy.calls.isEmpty, "no video, no hand-off: \(media)")
        }
    }

    func testInstagramVideoIsEnrichedAndNotDispatched() async throws {
        let note = try fileLinkNote(base: "2026-07-13 instagram.com", media: instagramReel)
        let spy = SpyTranscriptDispatching()
        let service = makeService(appState: makeAppState(), fetcher: FakeLinkFetcher(behavior: content(isVideo: true)), dispatch: spy)

        service.noteFiled(noteURL: note, in: output, echo: echo(instagramReel))
        await service.awaitIdle()

        XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent("Links/Media/2026-07-13 Bakery hours change.md").path), "enriched")
        XCTAssertTrue(spy.calls.isEmpty, "the pipeline cannot read Instagram videos without a login")
    }

    func testThreadsVideoIsEnrichedAndNotDispatched() async throws {
        let note = try fileLinkNote(base: "2026-07-13 threads.net", media: threadsPost)
        let spy = SpyTranscriptDispatching()
        let service = makeService(appState: makeAppState(), fetcher: FakeLinkFetcher(behavior: content(isVideo: true)), dispatch: spy)

        service.noteFiled(noteURL: note, in: output, echo: echo(threadsPost))
        await service.awaitIdle()

        XCTAssertTrue(spy.calls.isEmpty)
    }

    func testOrdinaryArticleStillReachesTheSeam() async throws {
        // Unchanged behavior (the dispatcher ignores it): the seam fires for
        // every enriched link that is not a social post.
        let article = "https://example.com/story"
        let note = try fileLinkNote(base: "2026-07-13 example.com", media: article)
        let spy = SpyTranscriptDispatching()
        let service = makeService(appState: makeAppState(), fetcher: FakeLinkFetcher(behavior: content(isVideo: false)), dispatch: spy)

        service.noteFiled(noteURL: note, in: output, echo: echo(article))
        await service.awaitIdle()

        XCTAssertEqual(spy.calls.count, 1)
    }

    func testOffersTranscriptTable() {
        let offers = LinkEnrichmentService.offersTranscript
        XCTAssertTrue(offers("https://youtu.be/abc", .youtubeLink, false))
        XCTAssertTrue(offers(facebookReel, .articleLink, true))
        XCTAssertFalse(offers(facebookReel, .articleLink, false))
        XCTAssertTrue(offers(xPost, .articleLink, true))
        XCTAssertFalse(offers(xPost, .articleLink, false))
        XCTAssertFalse(offers(instagramReel, .articleLink, true))
        XCTAssertFalse(offers(threadsPost, .articleLink, true))
        XCTAssertTrue(offers("https://example.com/story", .articleLink, false), "not a social post: the seam is unchanged")
        XCTAssertTrue(offers("https://notfacebook.com/story", .articleLink, false), "a look-alike host is an ordinary article")
    }

    // MARK: - Re-captured links (ledger dedup)

    func testRecapturedFacebookVideoDispatchesAgainWithoutARefetch() async throws {
        let first = try fileLinkNote(media: facebookReel)
        let spy = SpyTranscriptDispatching()
        let fetcher = FakeLinkFetcher(behavior: content(isVideo: true))
        let service = makeService(appState: makeAppState(), fetcher: fetcher, dispatch: spy)
        service.noteFiled(noteURL: first, in: output, echo: echo(facebookReel))
        await service.awaitIdle()

        let second = try fileLinkNote(base: "2026-07-15 facebook.com", media: facebookReel)
        service.noteFiled(noteURL: second, in: output, echo: echo(facebookReel))
        await service.awaitIdle()

        XCTAssertEqual(fetcher.totalCalls, 1, "zero re-fetch on a ledger hit")
        XCTAssertEqual(spy.calls.count, 2, "the stored video flag still offers the hand-off")
        XCTAssertEqual(spy.calls[1].noteRelativePath, "Links/2026-07-15 Bakery hours change.md")
    }

    func testRecapturedFacebookTextPostDoesNotDispatch() async throws {
        let first = try fileLinkNote(media: facebookPost)
        let spy = SpyTranscriptDispatching()
        let service = makeService(appState: makeAppState(), fetcher: FakeLinkFetcher(behavior: content(isVideo: false)), dispatch: spy)
        service.noteFiled(noteURL: first, in: output, echo: echo(facebookPost))
        await service.awaitIdle()

        let second = try fileLinkNote(base: "2026-07-15 facebook.com", media: facebookPost)
        service.noteFiled(noteURL: second, in: output, echo: echo(facebookPost))
        await service.awaitIdle()

        XCTAssertTrue(spy.calls.isEmpty)
    }

    func testRecapturedInstagramVideoNeverDispatches() async throws {
        let first = try fileLinkNote(media: instagramReel)
        let spy = SpyTranscriptDispatching()
        let service = makeService(appState: makeAppState(), fetcher: FakeLinkFetcher(behavior: content(isVideo: true)), dispatch: spy)
        service.noteFiled(noteURL: first, in: output, echo: echo(instagramReel))
        await service.awaitIdle()

        let second = try fileLinkNote(base: "2026-07-15 instagram.com", media: instagramReel)
        service.noteFiled(noteURL: second, in: output, echo: echo(instagramReel))
        await service.awaitIdle()

        XCTAssertTrue(spy.calls.isEmpty)
    }

    // MARK: - End to end with the real dispatcher

    private func makeDispatcher(appState: AppState) -> (TranscriptDispatchService, TranscriptDispatchLedger, FakeTranscriptSessionLauncher) {
        let ledger = TranscriptDispatchLedger(stateStore: appState.state)
        let launcher = FakeTranscriptSessionLauncher()
        return (TranscriptDispatchService(appState: appState, ledger: ledger, launcher: launcher), ledger, launcher)
    }

    func testFacebookVideoQueuesAndSpawnsWithTheSocialPostPrompt() async throws {
        let note = try fileLinkNote(media: facebookReel)
        let appState = makeAppState()
        let (dispatcher, ledger, launcher) = makeDispatcher(appState: appState)
        let service = makeService(appState: appState, fetcher: FakeLinkFetcher(behavior: content(isVideo: true)), dispatch: dispatcher)

        service.noteFiled(noteURL: note, in: output, echo: echo(facebookReel))
        await service.awaitIdle()
        XCTAssertEqual(ledger.records.count, 1)
        XCTAssertEqual(ledger.records.first?.status, .pending)

        await dispatcher.tick()

        XCTAssertEqual(launcher.launches.count, 1)
        let prompt = launcher.launches[0].prompt
        XCTAssertTrue(prompt.hasPrefix("Run the \"Social Post URL → Drive Transcript\" pipeline defined in AGENTS.md on this URL: \(facebookReel)\n"), prompt)
        XCTAssertTrue(prompt.contains(output.appendingPathComponent("Links/2026-07-13 Bakery hours change.md").path))
        XCTAssertEqual(launcher.launches[0].workingDirectory.path, pipelineFolder.path)
    }

    func testTurningTheSocialSettingOffMeansNoDispatch() async throws {
        let note = try fileLinkNote(media: facebookReel)
        let appState = makeAppState(socialToggle: false)
        let (dispatcher, ledger, launcher) = makeDispatcher(appState: appState)
        let service = makeService(appState: appState, fetcher: FakeLinkFetcher(behavior: content(isVideo: true)), dispatch: dispatcher)

        service.noteFiled(noteURL: note, in: output, echo: echo(facebookReel))
        await service.awaitIdle()
        await dispatcher.tick()

        XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent("Links/Media/2026-07-13 Bakery hours change.md").path), "still enriched")
        XCTAssertTrue(ledger.records.isEmpty, "nothing queued")
        XCTAssertTrue(launcher.launches.isEmpty)
    }

    func testTheYouTubeSettingDoesNotGovernSocialVideos() async throws {
        let note = try fileLinkNote(media: xPost)
        let appState = makeAppState()
        appState.settings.update { $0.autoTranscribeYouTube = false }
        let (dispatcher, ledger, launcher) = makeDispatcher(appState: appState)
        let service = makeService(appState: appState, fetcher: FakeLinkFetcher(behavior: content(isVideo: true)), dispatch: dispatcher)

        service.noteFiled(noteURL: note, in: output, echo: echo(xPost))
        await service.awaitIdle()
        await dispatcher.tick()

        XCTAssertEqual(ledger.records.count, 1)
        XCTAssertEqual(launcher.launches.count, 1)
    }

    func testInstagramVideoNeverQueuesEvenWithBothSettingsOn() async throws {
        let note = try fileLinkNote(media: instagramReel)
        let appState = makeAppState()
        let (dispatcher, ledger, launcher) = makeDispatcher(appState: appState)
        let service = makeService(appState: appState, fetcher: FakeLinkFetcher(behavior: content(isVideo: true)), dispatch: dispatcher)

        service.noteFiled(noteURL: note, in: output, echo: echo(instagramReel))
        await service.awaitIdle()
        await dispatcher.tick()

        XCTAssertTrue(ledger.records.isEmpty)
        XCTAssertTrue(launcher.launches.isEmpty)
    }
}
