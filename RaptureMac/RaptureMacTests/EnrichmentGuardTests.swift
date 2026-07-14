import XCTest
@testable import Rapture

/// The real fetcher is front-guarded on XCTest: constructing it is inert and
/// both entries throw before any I/O — the hosted suite can never reach the
/// network through enrichment.
@MainActor
final class EnrichmentGuardTests: XCTestCase {

    func testYouTubeFetchInertUnderTests() async {
        let fetcher = URLSessionLinkFetcher()
        do {
            _ = try await fetcher.fetchYouTube(videoID: "dQw4w9WgXcQ")
            XCTFail("fetcher must throw under XCTest — zero network from the suite")
        } catch {
            XCTAssertEqual(error as? LinkFetchError, .unavailable)
        }
    }

    func testArticleFetchInertUnderTests() async {
        let fetcher = URLSessionLinkFetcher()
        do {
            _ = try await fetcher.fetchArticle(url: URL(string: "https://example.com/post")!)
            XCTFail("fetcher must throw under XCTest — zero network from the suite")
        } catch {
            XCTAssertEqual(error as? LinkFetchError, .unavailable)
        }
    }
}
