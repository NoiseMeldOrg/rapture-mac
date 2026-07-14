import XCTest
@testable import Rapture

/// Golden tests for the readability-style extractor against inline HTML
/// fixtures. Real pages are messier; thin/garbage residue must come back nil
/// (the quiet-failure posture).
final class ArticleExtractorTests: XCTestCase {

    private let filler = String(repeating: "Sentence of body prose that keeps the residue above the usable floor. ", count: 6)

    // MARK: - Title

    func testOGTitleWinsOverTitleTag() {
        let html = #"""
        <html><head>
        <title>Post — Site Name</title>
        <meta property="og:title" content="The Real Headline">
        </head><body></body></html>
        """#
        XCTAssertEqual(ArticleExtractor.title(fromHTML: html), "The Real Headline")
    }

    func testTitleTagFallbackAndEntityDecode() {
        let html = "<html><head><title>Ben &amp; Jerry&#8217;s story</title></head><body></body></html>"
        XCTAssertEqual(ArticleExtractor.title(fromHTML: html), "Ben & Jerry\u{2019}s story")
    }

    func testReversedMetaAttributeOrder() {
        let html = #"<meta content="Reversed Order Title" property="og:title">"#
        XCTAssertEqual(ArticleExtractor.title(fromHTML: html), "Reversed Order Title")
    }

    func testNoTitleReturnsNil() {
        XCTAssertNil(ArticleExtractor.title(fromHTML: "<html><body>no title</body></html>"))
    }

    // MARK: - Readable text

    func testPrefersArticleTagAndStripsChrome() throws {
        let html = """
        <html><head><script>tracking();</script><style>.x{}</style></head>
        <body>
        <nav>Home | About | Contact</nav>
        <article><p>\(filler)</p><p>Second paragraph.</p></article>
        <footer>Copyright</footer>
        </body></html>
        """
        let text = try XCTUnwrap(ArticleExtractor.readableText(fromHTML: html))
        XCTAssertTrue(text.contains("Second paragraph."))
        XCTAssertFalse(text.contains("Home | About"))
        XCTAssertFalse(text.contains("tracking"))
        XCTAssertFalse(text.contains("Copyright"))
        XCTAssertTrue(text.contains("\n\n"), "paragraphs separated by blank lines")
    }

    func testMainTagFallbackWhenNoArticle() throws {
        let html = "<body><main><p>\(filler)</p></main><aside>Related links</aside></body>"
        let text = try XCTUnwrap(ArticleExtractor.readableText(fromHTML: html))
        XCTAssertTrue(text.contains("usable floor"))
        XCTAssertFalse(text.contains("Related links"))
    }

    func testWholeContainerFallbackWhenNoParagraphTags() throws {
        let html = "<body><div>\(filler)</div></body>"
        let text = try XCTUnwrap(ArticleExtractor.readableText(fromHTML: html))
        XCTAssertTrue(text.contains("usable floor"))
    }

    func testEntityDecodeInBody() throws {
        let html = "<article><p>\(filler) Fish &amp; chips &mdash; &quot;tasty&quot;&#33;</p></article>"
        let text = try XCTUnwrap(ArticleExtractor.readableText(fromHTML: html))
        XCTAssertTrue(text.contains("Fish & chips \u{2014} \"tasty\"!"))
    }

    func testListItemsBecomeDashes() throws {
        let html = "<article><p>\(filler)</p><ul><li>First item</li><li>Second item</li></ul></article>"
        let text = try XCTUnwrap(ArticleExtractor.readableText(fromHTML: html))
        XCTAssertTrue(text.contains("- First item"))
    }

    func testThinResidueReturnsNil() {
        XCTAssertNil(ArticleExtractor.readableText(fromHTML: "<body><p>Enable JavaScript to view.</p></body>"))
        XCTAssertNil(ArticleExtractor.readableText(fromHTML: ""))
    }

    func testCookieBannerShellReturnsNil() {
        let html = """
        <body><div id="consent"><button>Accept</button><button>Reject</button></div>
        <noscript>This site requires JavaScript.</noscript></body>
        """
        XCTAssertNil(ArticleExtractor.readableText(fromHTML: html))
    }

    func testCommentsStripped() throws {
        let html = "<article><!-- hidden --><p>\(filler)</p></article>"
        let text = try XCTUnwrap(ArticleExtractor.readableText(fromHTML: html))
        XCTAssertFalse(text.contains("hidden"))
    }
}
