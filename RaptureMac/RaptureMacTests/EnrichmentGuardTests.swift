import XCTest
@testable import Rapture

/// The real fetcher is front-guarded on XCTest: constructing it is inert and
/// every entry throws before any I/O, so the hosted suite can never reach the
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

    func testSocialPostFetchInertUnderTests() async {
        let fetcher = URLSessionLinkFetcher()
        let posts: [(String, SocialPost.Platform)] = [
            ("https://www.facebook.com/reel/1234567890/", .facebook),
            ("https://www.instagram.com/reel/AbC123/", .instagram),
            ("https://www.threads.net/@someone/post/B1", .threads),
            ("https://x.com/someone/status/1234567890", .x)
        ]
        for (post, platform) in posts {
            do {
                _ = try await fetcher.fetchSocialPost(url: URL(string: post)!, platform: platform)
                XCTFail("fetcher must throw under XCTest, zero network from the suite: \(post)")
            } catch {
                XCTAssertEqual(error as? LinkFetchError, .unavailable, post)
            }
        }
    }
}
