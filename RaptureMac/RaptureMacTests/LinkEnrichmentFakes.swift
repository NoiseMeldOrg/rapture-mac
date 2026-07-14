import Foundation
@testable import Rapture

/// Scriptable `LinkFetching` — behavior per call (the `FakeAITriageEngine`
/// shape): canned content, canned error, a per-call script, or an indefinite
/// cancellation-aware hang. Never touches the network.
@MainActor
final class FakeLinkFetcher: LinkFetching {
    enum Behavior {
        case content(FetchedLinkContent)
        case error(LinkFetchError)
        /// One behavior per successive call (last repeats); drives retry tests.
        case script([Behavior])
        /// Sleeps far past any test timeout; honors cancellation.
        case hang
    }

    var behavior: Behavior
    private(set) var youTubeCalls: [String] = []
    private(set) var articleCalls: [URL] = []
    private var scriptIndex = 0

    init(behavior: Behavior = .content(FetchedLinkContent(title: "Fetched Title", bodyMarkdown: "Fetched body."))) {
        self.behavior = behavior
    }

    var totalCalls: Int { youTubeCalls.count + articleCalls.count }

    func fetchYouTube(videoID: String) async throws -> FetchedLinkContent {
        youTubeCalls.append(videoID)
        return try await run(next())
    }

    func fetchArticle(url: URL) async throws -> FetchedLinkContent {
        articleCalls.append(url)
        return try await run(next())
    }

    private func next() -> Behavior {
        guard case .script(let steps) = behavior else { return behavior }
        let step = steps[min(scriptIndex, steps.count - 1)]
        scriptIndex += 1
        return step
    }

    private func run(_ behavior: Behavior) async throws -> FetchedLinkContent {
        switch behavior {
        case .content(let content):
            return content
        case .error(let error):
            throw error
        case .script(let steps):
            guard let first = steps.first else { throw LinkFetchError.unusableContent }
            return try await run(first)
        case .hang:
            try await Task.sleep(for: .seconds(3600))
            throw LinkFetchError.timeout
        }
    }
}
