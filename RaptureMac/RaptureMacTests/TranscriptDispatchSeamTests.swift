import XCTest
@testable import Rapture

/// The enrichment → transcript-dispatch seam: `LinkEnrichmentService` fires
/// `captureEnriched` with the note's FINAL (post-rename) relative path on both
/// the fresh and dedup `.done` paths, and never on give-up. Mirrors
/// `EnrichmentSeamTests` (fixtures from `LinkEnrichmentServiceTests`).
@MainActor
final class TranscriptDispatchSeamTests: XCTestCase {

    private let fm = FileManager.default
    private var root: URL!
    private var output: URL!
    private var support: URL!

    private let youtubeURL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("dispatch-seam-\(UUID().uuidString)", isDirectory: true)
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

    private func makeAppState() -> AppState {
        let appState = AppState(supportDirectory: support)
        appState.settings.update {
            $0.outputFolder = output
            $0.paused = false
            $0.triageMode = .full
            $0.linkEnrichmentEnabled = true
        }
        return appState
    }

    private func makeService(
        appState: AppState,
        fetcher: FakeLinkFetcher,
        spy: SpyTranscriptDispatching
    ) -> LinkEnrichmentService {
        LinkEnrichmentService(
            appState: appState,
            fetcher: fetcher,
            ledger: EnrichedLinkLedger(stateStore: appState.state),
            triageLedger: TriageLedger(stateStore: appState.state),
            transcriptDispatch: spy,
            retrySpacing: [0, 0],
            sleeper: { _ in }
        )
    }

    @discardableResult
    private func fileLinkNote(base: String) throws -> URL {
        let url = output.appendingPathComponent("Links/\(base).md")
        let content = """
        ---
        captured: 2026-07-13T12:00:00Z
        source: rapture-mac
        type: youtube-link
        raw_media: \(youtubeURL)
        ---

        \(youtubeURL)
        """
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func echo() -> LinkNoteEcho {
        // Midday UTC so the local calendar day is 2026-07-13 in every CI zone
        // (the LinkEnrichmentServiceTests rationale).
        LinkNoteEcho(type: .youtubeLink, rawMedia: youtubeURL, capturedAt: Date(timeIntervalSince1970: 1_783_944_000))
    }

    func testFreshEnrichmentFiresDispatchWithPostRenamePath() async throws {
        let noteURL = try fileLinkNote(base: "2026-07-13 YouTube dQw4w9WgXcQ")
        let appState = makeAppState()
        let spy = SpyTranscriptDispatching()
        let service = makeService(
            appState: appState,
            fetcher: FakeLinkFetcher(behavior: .content(FetchedLinkContent(
                title: "Real Video Title", bodyMarkdown: "T."))),
            spy: spy)

        service.noteFiled(noteURL: noteURL, in: output, echo: echo())
        await service.awaitIdle()

        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls[0].fingerprint, "yt:dQw4w9WgXcQ")
        XCTAssertEqual(spy.calls[0].url, youtubeURL)
        XCTAssertEqual(spy.calls[0].noteRelativePath, "Links/2026-07-13 Real Video Title.md",
                       "the POST-rename path, not the filed name")
    }

    func testDedupEnrichmentFiresDispatchWithFinalPath() async throws {
        let first = try fileLinkNote(base: "2026-07-13 YouTube dQw4w9WgXcQ")
        let appState = makeAppState()
        let spy = SpyTranscriptDispatching()
        let service = makeService(
            appState: appState,
            fetcher: FakeLinkFetcher(behavior: .content(FetchedLinkContent(
                title: "Real Video Title", bodyMarkdown: "T."))),
            spy: spy)

        service.noteFiled(noteURL: first, in: output, echo: echo())
        await service.awaitIdle()

        // Second capture of the same video: ledger dedup path, zero fetch.
        let second = try fileLinkNote(base: "2026-07-14 YouTube dQw4w9WgXcQ")
        service.noteFiled(noteURL: second, in: output, echo: echo())
        await service.awaitIdle()

        XCTAssertEqual(spy.calls.count, 2)
        XCTAssertEqual(spy.calls[1].fingerprint, "yt:dQw4w9WgXcQ")
        XCTAssertEqual(spy.calls[1].noteRelativePath, "Links/2026-07-14 Real Video Title.md",
                       "dedup rename applied before the hook fires")
    }

    func testGiveUpFiresNothing() async throws {
        let noteURL = try fileLinkNote(base: "2026-07-13 YouTube dQw4w9WgXcQ")
        let appState = makeAppState()
        let spy = SpyTranscriptDispatching()
        let service = makeService(
            appState: appState,
            fetcher: FakeLinkFetcher(behavior: .error(.noCaptions)),
            spy: spy)

        service.noteFiled(noteURL: noteURL, in: output, echo: echo())
        await service.awaitIdle()

        XCTAssertTrue(spy.calls.isEmpty, "give-up must not dispatch — the cron sweep is the net")
    }

    func testArticleEnrichmentPassesUrlFingerprintThrough() async throws {
        // The seam fires for every enriched link; filtering to `yt:` is the
        // dispatcher's job (TranscriptDispatchServiceTests cover the ignore).
        let articleURL = "https://example.com/post"
        let url = output.appendingPathComponent("Links/2026-07-13 example.com.md")
        try """
        ---
        captured: 2026-07-13T12:00:00Z
        source: rapture-mac
        type: article-link
        raw_media: \(articleURL)
        ---

        \(articleURL)
        """.write(to: url, atomically: true, encoding: .utf8)
        let appState = makeAppState()
        let spy = SpyTranscriptDispatching()
        let service = makeService(
            appState: appState,
            fetcher: FakeLinkFetcher(behavior: .content(FetchedLinkContent(title: "Post", bodyMarkdown: "B."))),
            spy: spy)

        service.noteFiled(
            noteURL: url, in: output,
            echo: LinkNoteEcho(type: .articleLink, rawMedia: articleURL, capturedAt: Date(timeIntervalSince1970: 1_783_944_000)))
        await service.awaitIdle()

        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertTrue(spy.calls[0].fingerprint.hasPrefix("url:"))
    }
}
