import XCTest
@testable import Rapture

/// Temp-dir integration tests for `LinkEnrichmentService`: the fetch → mutate
/// pipeline (artifact, rename, `Media:` append, ledgers), dedup, retries and
/// give-up, deferral, and races. Injected support directory + fake fetcher —
/// zero network, zero TCC, no real sleeps (injected sleeper).
@MainActor
final class LinkEnrichmentServiceTests: XCTestCase {

    private let fm = FileManager.default
    private var root: URL!
    private var output: URL!
    private var support: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("enrich-\(UUID().uuidString)", isDirectory: true)
        output = root.appendingPathComponent("Rapture Notes", isDirectory: true)
        support = root.appendingPathComponent("Support", isDirectory: true)
        try fm.createDirectory(at: output.appendingPathComponent("Links", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
    }

    // MARK: - Fixtures

    private func makeAppState(enabled: Bool = true) -> AppState {
        let appState = AppState(supportDirectory: support)
        appState.settings.update {
            $0.outputFolder = output
            $0.paused = false
            $0.triageMode = .full
            $0.linkEnrichmentEnabled = enabled
        }
        return appState
    }

    private func makeService(
        appState: AppState,
        fetcher: FakeLinkFetcher
    ) -> (LinkEnrichmentService, FakeLinkFetcher) {
        let service = LinkEnrichmentService(
            appState: appState,
            fetcher: fetcher,
            ledger: EnrichedLinkLedger(stateStore: appState.state),
            triageLedger: TriageLedger(stateStore: appState.state),
            retrySpacing: [0, 0],
            sleeper: { _ in }
        )
        return (service, fetcher)
    }

    private let youtubeURL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

    /// Files a contract-shaped link note the way the composers do.
    @discardableResult
    private func fileLinkNote(
        base: String = "2026-07-13 YouTube dQw4w9WgXcQ",
        rawMedia: String? = nil,
        footer: String = ""
    ) throws -> URL {
        let media = rawMedia ?? youtubeURL
        let url = output.appendingPathComponent("Links/\(base).md")
        let content = """
        ---
        captured: 2026-07-13T15:00:00Z
        source: rapture-mac
        type: youtube-link
        raw_media: \(media)
        ---

        \(media)
        \(footer)
        """
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func echo(type: CaptureType = .youtubeLink, rawMedia: String? = nil) -> LinkNoteEcho {
        LinkNoteEcho(type: type, rawMedia: rawMedia ?? youtubeURL, capturedAt: Date(timeIntervalSince1970: 1_784_000_000))
    }

    private func linksContents() throws -> [String] {
        try fm.contentsOfDirectory(atPath: output.appendingPathComponent("Links").path).sorted()
    }

    // MARK: - Happy paths

    func testYouTubeHappyPathRenamesWritesArtifactAndAppendsLink() async throws {
        let noteURL = try fileLinkNote()
        let appState = makeAppState()
        let (service, fetcher) = makeService(
            appState: appState,
            fetcher: FakeLinkFetcher(behavior: .content(FetchedLinkContent(
                title: "Real Video Title", bodyMarkdown: "Transcript paragraph."))))

        service.noteFiled(noteURL: noteURL, in: output, echo: echo())
        await service.awaitIdle()

        XCTAssertEqual(fetcher.youTubeCalls, ["dQw4w9WgXcQ"])
        let renamed = output.appendingPathComponent("Links/2026-07-13 Real Video Title.md")
        XCTAssertTrue(fm.fileExists(atPath: renamed.path), "note renamed to the real title")
        XCTAssertFalse(fm.fileExists(atPath: noteURL.path))

        let artifact = output.appendingPathComponent("Links/Media/2026-07-13 Real Video Title.md")
        XCTAssertTrue(fm.fileExists(atPath: artifact.path), "artifact in Links/Media")
        let artifactText = try String(contentsOf: artifact, encoding: .utf8)
        XCTAssertTrue(artifactText.contains("source: \(youtubeURL)"))
        XCTAssertTrue(artifactText.contains("capture: ../2026-07-13 Real Video Title.md"))
        XCTAssertTrue(artifactText.contains("type: youtube-transcript"))
        XCTAssertTrue(artifactText.hasSuffix("Transcript paragraph.\n"))

        let noteText = try String(contentsOf: renamed, encoding: .utf8)
        XCTAssertTrue(noteText.contains("Media:\n- [Real Video Title](<Media/2026-07-13 Real Video Title.md>)"))
        XCTAssertNil(appState.enrichmentLastError)

        let entry = EnrichedLinkLedger(stateStore: appState.state).entry(fingerprint: "yt:dQw4w9WgXcQ")
        XCTAssertEqual(entry?.title, "Real Video Title")
        XCTAssertEqual(entry?.artifactRelativePath, "Links/Media/2026-07-13 Real Video Title.md")
    }

    func testArticleHappyPath() async throws {
        let articleURL = "https://example.com/great-post?utm_source=x"
        let noteURL = try fileLinkNote(base: "2026-07-13 example.com", rawMedia: articleURL)
        let appState = makeAppState()
        let (service, fetcher) = makeService(
            appState: appState,
            fetcher: FakeLinkFetcher(behavior: .content(FetchedLinkContent(
                title: "The Great Post", bodyMarkdown: "Extracted text."))))

        service.noteFiled(noteURL: noteURL, in: output, echo: echo(type: .articleLink, rawMedia: articleURL))
        await service.awaitIdle()

        XCTAssertEqual(fetcher.articleCalls.map(\.absoluteString), [articleURL])
        XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent("Links/2026-07-13 The Great Post.md").path))
        let artifact = output.appendingPathComponent("Links/Media/2026-07-13 The Great Post.md")
        XCTAssertTrue(try String(contentsOf: artifact, encoding: .utf8).contains("type: article-extract"))

        let entry = EnrichedLinkLedger(stateStore: appState.state).entry(fingerprint: "url:https://example.com/great-post")
        XCTAssertNotNil(entry, "fingerprint uses the normalized URL (utm stripped)")
    }

    func testNoTitleSkipsRenameButStillEnriches() async throws {
        let noteURL = try fileLinkNote()
        let appState = makeAppState()
        let (service, _) = makeService(
            appState: appState,
            fetcher: FakeLinkFetcher(behavior: .content(FetchedLinkContent(title: nil, bodyMarkdown: "Body."))))

        service.noteFiled(noteURL: noteURL, in: output, echo: echo())
        await service.awaitIdle()

        XCTAssertTrue(fm.fileExists(atPath: noteURL.path), "deterministic name kept")
        let noteText = try String(contentsOf: noteURL, encoding: .utf8)
        XCTAssertTrue(noteText.contains("Media:\n- ["), "artifact link still appended")
        XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent("Links/Media/2026-07-13 YouTube Transcript.md").path))
    }

    func testRenameCollisionWalksSuffix() async throws {
        try fileLinkNote(base: "2026-07-13 Real Video Title")   // squatter on the target name
        let noteURL = try fileLinkNote()
        let appState = makeAppState()
        let (service, _) = makeService(
            appState: appState,
            fetcher: FakeLinkFetcher(behavior: .content(FetchedLinkContent(
                title: "Real Video Title", bodyMarkdown: "T."))))

        service.noteFiled(noteURL: noteURL, in: output, echo: echo())
        await service.awaitIdle()

        XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent("Links/2026-07-13 Real Video Title-1.md").path))
    }

    func testAttachmentPairRenamesInLockstepWithFooterRewrite() async throws {
        let base = "2026-07-13 YouTube dQw4w9WgXcQ"
        let attachmentDir = output.appendingPathComponent("Links/\(base)", isDirectory: true)
        try fm.createDirectory(at: attachmentDir, withIntermediateDirectories: true)
        try Data("img".utf8).write(to: attachmentDir.appendingPathComponent("photo.png"))
        let noteURL = try fileLinkNote(footer: "\nAttachments:\n- [photo.png](<\(base)/photo.png>)")

        let appState = makeAppState()
        let (service, _) = makeService(
            appState: appState,
            fetcher: FakeLinkFetcher(behavior: .content(FetchedLinkContent(
                title: "Real Video Title", bodyMarkdown: "T."))))
        service.noteFiled(noteURL: noteURL, in: output, echo: echo())
        await service.awaitIdle()

        let renamedDir = output.appendingPathComponent("Links/2026-07-13 Real Video Title", isDirectory: true)
        XCTAssertTrue(fm.fileExists(atPath: renamedDir.appendingPathComponent("photo.png").path), "pair moved in lockstep")
        let noteText = try String(
            contentsOf: output.appendingPathComponent("Links/2026-07-13 Real Video Title.md"), encoding: .utf8)
        XCTAssertTrue(noteText.contains("- [photo.png](<2026-07-13 Real Video Title/photo.png>)"), "footer rewritten")
        XCTAssertTrue(noteText.contains("Media:\n"), "media link appended")
        let mediaRange = try XCTUnwrap(noteText.range(of: "Media:\n"))
        let footerRange = try XCTUnwrap(noteText.range(of: "Attachments:\n"))
        XCTAssertLessThan(mediaRange.lowerBound, footerRange.lowerBound)
    }

    func testTriageLedgerRemappedAfterRename() async throws {
        let noteURL = try fileLinkNote()
        let appState = makeAppState()
        let triageLedger = TriageLedger(stateStore: appState.state)
        triageLedger.record(
            sourceFilename: "2026-07-13T15-00-00Z.txt",
            contentHash: "h",
            mdRelativePath: "Links/2026-07-13 YouTube dQw4w9WgXcQ.md")
        let (service, _) = makeService(
            appState: appState,
            fetcher: FakeLinkFetcher(behavior: .content(FetchedLinkContent(title: "Real Video Title", bodyMarkdown: "T."))))

        service.noteFiled(noteURL: noteURL, in: output, echo: echo())
        await service.awaitIdle()

        XCTAssertEqual(
            triageLedger.entry(sourceFilename: "2026-07-13T15-00-00Z.txt")?.mdRelativePath,
            "Links/2026-07-13 Real Video Title.md")
    }

    // MARK: - Dedup

    func testRecapturedLinkUsesExistingArtifactWithoutRefetch() async throws {
        let first = try fileLinkNote()
        let appState = makeAppState()
        let (service, fetcher) = makeService(
            appState: appState,
            fetcher: FakeLinkFetcher(behavior: .content(FetchedLinkContent(title: "Real Video Title", bodyMarkdown: "T."))))
        service.noteFiled(noteURL: first, in: output, echo: echo())
        await service.awaitIdle()
        XCTAssertEqual(fetcher.totalCalls, 1)

        // Same video captured again days later, different note.
        let second = try fileLinkNote(base: "2026-07-15 YouTube dQw4w9WgXcQ")
        service.noteFiled(noteURL: second, in: output, echo: echo())
        await service.awaitIdle()

        XCTAssertEqual(fetcher.totalCalls, 1, "zero re-fetch on ledger hit")
        let renamedSecond = output.appendingPathComponent("Links/2026-07-15 Real Video Title.md")
        XCTAssertTrue(fm.fileExists(atPath: renamedSecond.path), "re-capture renamed from the stored title")
        let text = try String(contentsOf: renamedSecond, encoding: .utf8)
        XCTAssertTrue(text.contains("(<Media/2026-07-13 Real Video Title.md>)"), "points at the EXISTING artifact")
        let artifacts = try fm.contentsOfDirectory(atPath: output.appendingPathComponent("Links/Media").path)
        XCTAssertEqual(artifacts.count, 1, "no second artifact")
    }

    func testLedgerHitWithDeletedArtifactRefetches() async throws {
        let first = try fileLinkNote()
        let appState = makeAppState()
        let (service, fetcher) = makeService(
            appState: appState,
            fetcher: FakeLinkFetcher(behavior: .content(FetchedLinkContent(title: "Real Video Title", bodyMarkdown: "T."))))
        service.noteFiled(noteURL: first, in: output, echo: echo())
        await service.awaitIdle()

        // User deletes the artifact; the same link arrives again.
        try fm.removeItem(at: output.appendingPathComponent("Links/Media/2026-07-13 Real Video Title.md"))
        let second = try fileLinkNote(base: "2026-07-15 YouTube dQw4w9WgXcQ")
        service.noteFiled(noteURL: second, in: output, echo: echo())
        await service.awaitIdle()

        XCTAssertEqual(fetcher.totalCalls, 2, "missing artifact falls through to a fresh fetch")
        XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent("Links/Media/2026-07-13 Real Video Title.md").path))
    }

    func testConcurrentDuplicateCoalescesOntoOneFetch() async throws {
        let first = try fileLinkNote()
        let second = try fileLinkNote(base: "2026-07-13 YouTube dQw4w9WgXcQ-1")
        let appState = makeAppState()
        let (service, fetcher) = makeService(
            appState: appState,
            fetcher: FakeLinkFetcher(behavior: .content(FetchedLinkContent(title: "Real Video Title", bodyMarkdown: "T."))))

        service.noteFiled(noteURL: first, in: output, echo: echo())
        service.noteFiled(noteURL: second, in: output, echo: echo())
        await service.awaitIdle()

        XCTAssertEqual(fetcher.totalCalls, 1, "one fetch services both notes")
        XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent("Links/2026-07-13 Real Video Title.md").path))
        XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent("Links/2026-07-13 Real Video Title-1.md").path))
        let artifacts = try fm.contentsOfDirectory(atPath: output.appendingPathComponent("Links/Media").path)
        XCTAssertEqual(artifacts.count, 1)
    }

    // MARK: - Failure posture

    func testTransportErrorRetriesThenGivesUpQuietly() async throws {
        let noteURL = try fileLinkNote()
        let before = try String(contentsOf: noteURL, encoding: .utf8)
        let appState = makeAppState()
        let (service, fetcher) = makeService(
            appState: appState,
            fetcher: FakeLinkFetcher(behavior: .error(.timeout)))

        service.noteFiled(noteURL: noteURL, in: output, echo: echo())
        await service.awaitIdle()

        XCTAssertEqual(fetcher.totalCalls, LinkEnrichmentService.maxAttempts, "3 attempts then give-up")
        XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), before, "note untouched")
        XCTAssertFalse(fm.fileExists(atPath: output.appendingPathComponent("Links/Media").path))
        XCTAssertNotNil(appState.enrichmentLastError, "Settings-only line set")
        XCTAssertNil(appState.lastError, "never the menu-bar error surface")
    }

    func testContentErrorGivesUpOnFirstAttempt() async throws {
        let noteURL = try fileLinkNote()
        let appState = makeAppState()
        let (service, fetcher) = makeService(appState: appState, fetcher: FakeLinkFetcher(behavior: .error(.noCaptions)))

        service.noteFiled(noteURL: noteURL, in: output, echo: echo())
        await service.awaitIdle()

        XCTAssertEqual(fetcher.totalCalls, 1, "no retry for content-class failures")
    }

    func testTransientErrorThenSuccessRecovers() async throws {
        let noteURL = try fileLinkNote()
        let appState = makeAppState()
        let (service, fetcher) = makeService(
            appState: appState,
            fetcher: FakeLinkFetcher(behavior: .script([
                .error(.network("down")),
                .content(FetchedLinkContent(title: "Real Video Title", bodyMarkdown: "T."))
            ])))

        service.noteFiled(noteURL: noteURL, in: output, echo: echo())
        await service.awaitIdle()

        XCTAssertEqual(fetcher.totalCalls, 2)
        XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent("Links/2026-07-13 Real Video Title.md").path))
        XCTAssertNil(appState.enrichmentLastError, "cleared on success")
    }

    func testConsecutiveTransportJobFailuresSetCooldown() async throws {
        let noteA = try fileLinkNote()
        let noteB = try fileLinkNote(base: "2026-07-13 example.com", rawMedia: "https://example.com/a")
        let appState = makeAppState()
        var sleeps: [TimeInterval] = []
        let fetcher = FakeLinkFetcher(behavior: .error(.timeout))
        let service = LinkEnrichmentService(
            appState: appState,
            fetcher: fetcher,
            ledger: EnrichedLinkLedger(stateStore: appState.state),
            triageLedger: TriageLedger(stateStore: appState.state),
            retrySpacing: [0, 0],
            sleeper: { @MainActor in sleeps.append($0) }
        )

        service.noteFiled(noteURL: noteA, in: output, echo: echo())
        service.noteFiled(noteURL: noteB, in: output, echo: echo(type: .articleLink, rawMedia: "https://example.com/a"))
        // A third job arriving after two failed jobs must wait out the cooldown.
        let noteC = try fileLinkNote(base: "2026-07-13 example.org", rawMedia: "https://example.org/b")
        service.noteFiled(noteURL: noteC, in: output, echo: echo(type: .articleLink, rawMedia: "https://example.org/b"))
        await service.awaitIdle()

        XCTAssertTrue(sleeps.contains(where: { $0 > 1 }), "a cooldown-scale sleep occurred: \(sleeps)")
    }

    // MARK: - Gates and races

    func testToggleOffMeansNoJob() async throws {
        let noteURL = try fileLinkNote()
        let appState = makeAppState(enabled: false)
        let (service, fetcher) = makeService(appState: appState, fetcher: FakeLinkFetcher())

        service.noteFiled(noteURL: noteURL, in: output, echo: echo())
        await service.awaitIdle()

        XCTAssertEqual(fetcher.totalCalls, 0)
    }

    func testToggleOffMidFlightDropsBeforeMutation() async throws {
        let noteURL = try fileLinkNote()
        let before = try String(contentsOf: noteURL, encoding: .utf8)
        let appState = makeAppState()
        let (service, _) = makeService(
            appState: appState,
            fetcher: FakeLinkFetcher(behavior: .content(FetchedLinkContent(title: "Real Video Title", bodyMarkdown: "T."))))

        // Enqueued with the toggle on; disabled before the worker's gated
        // mutation pass runs (Phase B re-checks the toggle and must drop).
        service.noteFiled(noteURL: noteURL, in: output, echo: echo())
        appState.settings.update { $0.linkEnrichmentEnabled = false }
        await service.awaitIdle()

        XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), before, "note untouched after mid-flight disable")
        XCTAssertFalse(fm.fileExists(atPath: output.appendingPathComponent("Links/Media").path))
    }

    func testPausedDefersThenCompletesOnResume() async throws {
        let noteURL = try fileLinkNote()
        let appState = makeAppState()
        appState.settings.update { $0.paused = true }
        var deferrals = 0
        let service = LinkEnrichmentService(
            appState: appState,
            fetcher: FakeLinkFetcher(behavior: .content(FetchedLinkContent(title: "Real Video Title", bodyMarkdown: "T."))),
            ledger: EnrichedLinkLedger(stateStore: appState.state),
            triageLedger: TriageLedger(stateStore: appState.state),
            retrySpacing: [0, 0],
            sleeper: { @MainActor _ in
                deferrals += 1
                if deferrals >= 2 {
                    appState.settings.update { $0.paused = false }
                }
            }
        )

        service.noteFiled(noteURL: noteURL, in: output, echo: echo())
        await service.awaitIdle()

        XCTAssertGreaterThanOrEqual(deferrals, 2, "mutation deferred while paused")
        XCTAssertTrue(fm.fileExists(atPath: output.appendingPathComponent("Links/2026-07-13 Real Video Title.md").path))
    }

    func testNoteDeletedBeforeEnrichmentDropsWithoutArtifact() async throws {
        let noteURL = try fileLinkNote()
        let appState = makeAppState()
        let fetcher = FakeLinkFetcher(behavior: .content(FetchedLinkContent(title: "Real Video Title", bodyMarkdown: "T.")))
        let (service, _) = makeService(appState: appState, fetcher: fetcher)

        service.noteFiled(noteURL: noteURL, in: output, echo: echo())
        try fm.removeItem(at: noteURL)
        await service.awaitIdle()

        XCTAssertFalse(fm.fileExists(atPath: output.appendingPathComponent("Links/Media").path),
                       "never orphan an artifact whose capture pointer is stillborn")
        XCTAssertNil(EnrichedLinkLedger(stateStore: appState.state).entry(fingerprint: "yt:dQw4w9WgXcQ"))
    }

    func testNonContractNoteNameIsNotRenamed() async throws {
        let noteURL = try fileLinkNote(base: "custom name without date")
        let appState = makeAppState()
        let (service, _) = makeService(
            appState: appState,
            fetcher: FakeLinkFetcher(behavior: .content(FetchedLinkContent(title: "Real Video Title", bodyMarkdown: "T."))))

        service.noteFiled(noteURL: noteURL, in: output, echo: echo())
        await service.awaitIdle()

        XCTAssertTrue(fm.fileExists(atPath: noteURL.path), "non-contract name kept")
        XCTAssertTrue(try String(contentsOf: noteURL, encoding: .utf8).contains("Media:\n"), "still enriched")
    }

    func testStopClearsQueue() async throws {
        let noteURL = try fileLinkNote()
        let appState = makeAppState()
        let (service, _) = makeService(appState: appState, fetcher: FakeLinkFetcher(behavior: .hang))

        service.noteFiled(noteURL: noteURL, in: output, echo: echo())
        service.stop()
        XCTAssertTrue(service.queue.isEmpty)
    }
}
