import XCTest
@testable import Rapture

/// Pure tests for `SocialPost`: platform detection, the meta-tag scanner, the
/// per-platform text rules, login walls, X embed-feed and oEmbed text, titles
/// and video detection. Every fixture is invented; no network, no fetcher.
final class SocialPostTests: XCTestCase {

    private func url(_ string: String) -> URL { URL(string: string)! }

    private func json(_ object: [String: Any]) -> Data {
        // swiftlint:disable:next force_try
        try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - Platform detection

    func testPlatformsByHost() {
        let platform = { (s: String) in SocialPost.platform(for: self.url(s)) }
        XCTAssertEqual(platform("https://www.facebook.com/share/v/ABC123/"), .facebook)
        XCTAssertEqual(platform("https://facebook.com/somepage/posts/1"), .facebook)
        XCTAssertEqual(platform("https://m.facebook.com/somepage/posts/1"), .facebook)
        XCTAssertEqual(platform("https://fb.watch/abc/"), .facebook)
        XCTAssertEqual(platform("https://www.instagram.com/reel/AbC/"), .instagram)
        XCTAssertEqual(platform("https://instagr.am/p/AbC/"), .instagram)
        XCTAssertEqual(platform("https://www.threads.net/@someone/post/B"), .threads)
        XCTAssertEqual(platform("https://www.threads.com/@someone/post/B"), .threads)
        XCTAssertEqual(platform("https://x.com/someone/status/20"), .x)
        XCTAssertEqual(platform("https://mobile.x.com/someone/status/20"), .x)
        XCTAssertEqual(platform("https://twitter.com/someone/status/20"), .x)
    }

    func testHostMatchIsCaseInsensitive() {
        XCTAssertEqual(SocialPost.platform(forHost: "WWW.Facebook.COM"), .facebook)
        XCTAssertEqual(SocialPost.platform(forHost: "X.com"), .x)
    }

    func testLookAlikeHostsAreRejected() {
        for host in [
            "notfacebook.com", "facebook.com.evil.example", "evilfb.watch", "fb.watch.evil.example",
            "netflix.com", "box.com", "fakex.com", "evilthreads.net", "twitter.com.example.org",
            "myinstagram.com", "instagram.com.evil.example", "example.com", ""
        ] {
            XCTAssertNil(SocialPost.platform(forHost: host), "\(host) must not match")
        }
    }

    func testURLWithoutHostIsNotSocial() {
        XCTAssertNil(SocialPost.platform(for: url("mailto:someone@example.com")))
        XCTAssertNil(SocialPost.platform(for: url("file:///tmp/facebook.com")))
    }

    func testOnlyFacebookAndXCanTranscribeVideo() {
        XCTAssertTrue(SocialPost.Platform.facebook.canTranscribeVideo)
        XCTAssertTrue(SocialPost.Platform.x.canTranscribeVideo)
        XCTAssertFalse(SocialPost.Platform.instagram.canTranscribeVideo)
        XCTAssertFalse(SocialPost.Platform.threads.canTranscribeVideo)
    }

    // MARK: - Video URLs

    func testVideoURLs() {
        XCTAssertTrue(SocialPost.looksLikeVideoURL(url("https://www.facebook.com/reel/1234567890/")))
        XCTAssertTrue(SocialPost.looksLikeVideoURL(url("https://www.facebook.com/reels/1234567890/")))
        XCTAssertTrue(SocialPost.looksLikeVideoURL(url("https://www.facebook.com/share/v/ABC123/")))
        XCTAssertTrue(SocialPost.looksLikeVideoURL(url("https://www.facebook.com/share/r/ABC123/")))
        XCTAssertTrue(SocialPost.looksLikeVideoURL(url("https://www.facebook.com/somepage/videos/99/")))
        XCTAssertTrue(SocialPost.looksLikeVideoURL(url("https://www.facebook.com/watch/?v=99")))
        XCTAssertTrue(SocialPost.looksLikeVideoURL(url("https://fb.watch/abc/")))
        XCTAssertTrue(SocialPost.looksLikeVideoURL(url("https://www.instagram.com/reel/AbC/")))
    }

    func testNonVideoURLs() {
        XCTAssertFalse(SocialPost.looksLikeVideoURL(url("https://www.facebook.com/share/p/ABC123/")))
        XCTAssertFalse(SocialPost.looksLikeVideoURL(url("https://www.facebook.com/somepage/posts/99")))
        XCTAssertFalse(SocialPost.looksLikeVideoURL(url("https://www.instagram.com/p/AbC/")))
        XCTAssertFalse(SocialPost.looksLikeVideoURL(url("https://x.com/someone/status/20")))
    }

    // MARK: - Tweet IDs

    func testTweetIDFromSeveralShapes() {
        XCTAssertEqual(SocialPost.tweetID(from: url("https://x.com/someone/status/20?s=20")), "20")
        XCTAssertEqual(SocialPost.tweetID(from: url("https://twitter.com/someone/status/1234567890123456789")), "1234567890123456789")
        XCTAssertEqual(SocialPost.tweetID(from: url("https://x.com/i/web/status/1234567890123456789")), "1234567890123456789")
        XCTAssertEqual(SocialPost.tweetID(from: url("https://x.com/someone/statuses/77")), "77")
        XCTAssertEqual(SocialPost.tweetID(from: url("https://x.com/someone/status/55/photo/1")), "55")
        XCTAssertEqual(SocialPost.tweetID(from: url("https://mobile.twitter.com/someone/status/31#reply")), "31")
    }

    func testTweetIDAbsent() {
        XCTAssertNil(SocialPost.tweetID(from: url("https://x.com/someone")))
        XCTAssertNil(SocialPost.tweetID(from: url("https://x.com/someone/status/")))
        XCTAssertNil(SocialPost.tweetID(from: url("https://x.com/someone/status/abc")))
        XCTAssertNil(SocialPost.tweetID(from: url("https://x.com/home")))
    }

    // MARK: - Request shapes

    func testSyndicationURLShape() {
        XCTAssertEqual(
            SocialPost.syndicationURL(tweetID: "1234567890")?.absoluteString,
            "https://cdn.syndication.twimg.com/tweet-result?id=1234567890&lang=en&token=a")
    }

    func testSyndicationURLRefusesAnythingButDigits() {
        XCTAssertNil(SocialPost.syndicationURL(tweetID: ""))
        XCTAssertNil(SocialPost.syndicationURL(tweetID: "20&x=1"))
        XCTAssertNil(SocialPost.syndicationURL(tweetID: "../20"))
        XCTAssertNil(SocialPost.syndicationURL(tweetID: "\u{FF12}\u{FF10}"), "full-width digits are not tweet IDs")
    }

    func testOEmbedURLPercentEncodesThePostURL() {
        let oEmbed = SocialPost.oEmbedURL(forPostURL: url("https://x.com/someone/status/20?s=20&t=abc"))
        XCTAssertEqual(
            oEmbed?.absoluteString,
            "https://publish.twitter.com/oembed?omit_script=1&url=https%3A%2F%2Fx.com%2Fsomeone%2Fstatus%2F20%3Fs%3D20%26t%3Dabc")
        XCTAssertEqual(oEmbed?.host, "publish.twitter.com")
    }

    func testCrawlerUserAgentIsMetasOwn() {
        XCTAssertEqual(
            SocialPost.crawlerUserAgent,
            "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)")
    }

    // MARK: - Engagement prefix

    func testEngagementPrefixVariants() {
        XCTAssertEqual(SocialPost.stripEngagementPrefix("36 reactions · 3 comments | Hello there"), "Hello there")
        XCTAssertEqual(SocialPost.stripEngagementPrefix("1.2K views · 45 reactions | Title | Some Page"), "Title | Some Page")
        XCTAssertEqual(SocialPost.stripEngagementPrefix("No reactions | Hi"), "Hi")
        XCTAssertEqual(SocialPost.stripEngagementPrefix("1 comment | Hi"), "Hi")
        XCTAssertEqual(SocialPost.stripEngagementPrefix("12K views · 3.4K reactions · 200 comments | Big news"), "Big news")
        XCTAssertEqual(SocialPost.stripEngagementPrefix("2 shares | Hi"), "Hi")
        XCTAssertEqual(SocialPost.stripEngagementPrefix("  7 likes | Hi"), "Hi")
    }

    func testEngagementWordsInTheMiddleStayUntouched() {
        XCTAssertEqual(
            SocialPost.stripEngagementPrefix("Plain text, 5 reactions are nice"),
            "Plain text, 5 reactions are nice")
        XCTAssertEqual(
            SocialPost.stripEngagementPrefix("We got 40 comments | on the last post"),
            "We got 40 comments | on the last post")
        XCTAssertEqual(SocialPost.stripEngagementPrefix("Reactions were mixed"), "Reactions were mixed")
        XCTAssertEqual(SocialPost.stripEngagementPrefix("Hello"), "Hello")
    }

    // MARK: - Login walls

    func testLoginWallDetection() {
        XCTAssertTrue(SocialPost.isLoginWall(""))
        XCTAssertTrue(SocialPost.isLoginWall("   "))
        XCTAssertTrue(SocialPost.isLoginWall("Facebook"))
        XCTAssertTrue(SocialPost.isLoginWall("Instagram"))
        XCTAssertTrue(SocialPost.isLoginWall("Threads"))
        XCTAssertTrue(SocialPost.isLoginWall("Log in or sign up to view"))
        XCTAssertTrue(SocialPost.isLoginWall("See posts, photos and more on Facebook."))
        XCTAssertTrue(SocialPost.isLoginWall("Log into Facebook to start sharing and connecting with your friends."))
        XCTAssertTrue(SocialPost.isLoginWall("Create an account or log in to Instagram - share photos and videos."))
        XCTAssertTrue(SocialPost.isLoginWall("Join Threads to share ideas, ask questions, post random thoughts."))
        XCTAssertFalse(SocialPost.isLoginWall("A real post about login pages and Facebook"))
    }

    func testFacebookLoginWallGivesNoText() {
        XCTAssertEqual(SocialPost.facebookText(meta: [
            "og:title": "Log in or sign up to view",
            "og:description": "See posts, photos and more on Facebook."
        ]), "")
        XCTAssertEqual(SocialPost.facebookText(meta: [
            "og:title": "Facebook",
            "og:description": "Log into Facebook to start sharing and connecting with your friends, family, and people you know."
        ]), "")
        XCTAssertEqual(SocialPost.facebookText(meta: ["og:title": "Log in to Facebook"]), "")
        XCTAssertEqual(SocialPost.facebookText(meta: [:]), "")
    }

    func testInstagramLoginWallGivesNoText() {
        XCTAssertEqual(SocialPost.instagramText(meta: [
            "og:title": "Instagram",
            "og:description": "Create an account or log in to Instagram - A simple, fun & creative way to capture, edit & share photos."
        ]), "")
        XCTAssertEqual(SocialPost.instagramText(meta: ["og:title": "Login \u{2022} Instagram"]), "")
        XCTAssertEqual(SocialPost.instagramText(meta: [:]), "")
    }

    func testThreadsLoginWallGivesNoText() {
        XCTAssertEqual(SocialPost.threadsText(meta: [
            "og:description": "Join Threads to share ideas, ask questions, post random thoughts, find your people."
        ]), "")
        XCTAssertEqual(SocialPost.threadsText(meta: [:]), "")
    }

    func testRealPostThatMentionsLoginPagesIsKept() {
        XCTAssertEqual(
            SocialPost.facebookText(meta: ["og:title": "A real post about login pages and Facebook", "og:description": ""]),
            "A real post about login pages and Facebook")
    }

    // MARK: - Per-platform text

    func testFacebookTitleHoldsTheWholePost() {
        let meta = [
            "og:title": "36 reactions · 3 comments | Garden club moved to Thursday.\n\nBring a folding chair, the hall is short on seats.",
            "og:description": "Garden club moved to Thursday.\n\nBring a folding chair, the hall is sh..."
        ]
        XCTAssertEqual(
            SocialPost.facebookText(meta: meta),
            "Garden club moved to Thursday.\n\nBring a folding chair, the hall is short on seats.")
    }

    func testFacebookFallsBackToALongerDescription() {
        let meta = ["og:title": "2 reactions | Short", "og:description": "Short, with a longer description."]
        XCTAssertEqual(SocialPost.facebookText(meta: meta), "Short, with a longer description.")
    }

    func testFacebookNormalizesWindowsLineEndings() {
        XCTAssertEqual(SocialPost.facebookText(meta: ["og:title": "Line one.\r\nLine two."]), "Line one.\nLine two.")
    }

    func testFacebookTextDecodesEntitiesLeftInTheTag() {
        // Meta pages sometimes encode the title twice; the scanner decodes the
        // tag value and the text rule decodes once more, like the reference.
        XCTAssertEqual(SocialPost.facebookText(meta: ["og:title": "Tom &amp; Jerry"]), "Tom & Jerry")
    }

    func testInstagramCaptionFromTitle() {
        let meta = ["og:title": "Pat Example (@patexample) on Instagram: \"Sunset at the lake \u{1F305}\""]
        XCTAssertEqual(SocialPost.instagramText(meta: meta), "Sunset at the lake \u{1F305}")
    }

    func testInstagramCaptionFromTitleWithCurlyQuotesAndNewlines() {
        let meta = ["og:title": "Pat Example (@patexample) on Instagram: \u{201C}Line one\nLine two\u{201D}"]
        XCTAssertEqual(SocialPost.instagramText(meta: meta), "Line one\nLine two")
    }

    func testInstagramCaptionFromDescription() {
        let meta = ["og:description": "1,234 likes, 56 comments - patexample on March 3, 2026: \"Caption here\"."]
        XCTAssertEqual(SocialPost.instagramText(meta: meta), "Caption here")
    }

    func testInstagramCaptionKeepsInnerQuotes() {
        let meta = ["og:title": "Pat Example (@patexample) on Instagram: \"She said \"hello\" to me\""]
        XCTAssertEqual(SocialPost.instagramText(meta: meta), "She said \"hello\" to me")
    }

    func testInstagramWithoutACaptionGivesNothing() {
        XCTAssertEqual(SocialPost.instagramText(meta: ["og:title": "Pat Example (@patexample) on Instagram"]), "")
    }

    func testThreadsTextIsTheDescription() {
        XCTAssertEqual(SocialPost.threadsText(meta: ["og:description": "Hello from threads"]), "Hello from threads")
    }

    func testTextForPlatformDispatches() {
        let meta = ["og:title": "Hello", "og:description": "World wide"]
        XCTAssertEqual(SocialPost.text(for: .facebook, meta: meta), "World wide")
        XCTAssertEqual(SocialPost.text(for: .threads, meta: meta), "World wide")
        XCTAssertEqual(SocialPost.text(for: .instagram, meta: meta), "")
        XCTAssertEqual(SocialPost.text(for: .x, meta: meta), "", "X never reads meta tags")
    }

    // MARK: - Meta scanner

    func testMetaScannerHandlesAttributeOrdersAndQuoteStyles() {
        let page = """
        <html><head>\
        <meta content="B" property="og:title">\
        <meta property='og:type' content='video.other'>\
        <meta name=og:locale content=en_US>\
        <meta property="og:title" content="second">\
        </head>
        """
        let meta = SocialPost.parseMeta(page)
        XCTAssertEqual(meta["og:title"], "B", "first tag of a name wins")
        XCTAssertEqual(meta["og:type"], "video.other")
        XCTAssertEqual(meta["og:locale"], "en_US", "unquoted values and name= both work")
    }

    func testMetaScannerIsCaseInsensitiveOnTagsAndAttributeNames() {
        let meta = SocialPost.parseMeta(#"<META PROPERTY="OG:Title" CONTENT="Shouting">"#)
        XCTAssertEqual(meta["og:title"], "Shouting")
    }

    func testMetaScannerKeepsAGreaterThanSignInsideAQuotedValue() {
        let meta = SocialPost.parseMeta(#"<meta property="og:title" content="a > b and c < d"><meta property="og:type" content="article">"#)
        XCTAssertEqual(meta["og:title"], "a > b and c < d")
        XCTAssertEqual(meta["og:type"], "article")
    }

    func testMetaScannerDecodesEntitiesInValues() {
        let meta = SocialPost.parseMeta(#"<meta property="og:title" content="Tom &amp; Jerry&#039;s &quot;show&quot; &#x1F600;">"#)
        XCTAssertEqual(meta["og:title"], "Tom & Jerry's \"show\" \u{1F600}")
    }

    func testMetaScannerSkipsCommentsScriptsAndStyles() {
        let page = """
        <!-- <meta property="og:title" content="in a comment"> -->\
        <script>var s = '<meta property="og:title" content="in a script">';</script>\
        <style>/* <meta property="og:title" content="in a style"> */</style>\
        <meta property="og:title" content="the real one">
        """
        XCTAssertEqual(SocialPost.parseMeta(page)["og:title"], "the real one")
    }

    func testMetaScannerIgnoresLookAlikeTagsAndTagsWithoutContent() {
        let page = """
        <metadata property="og:title" content="not a meta tag">\
        <meta property="og:description">\
        <meta charset="utf-8">\
        <meta property="og:site_name" content="Some Site">
        """
        let meta = SocialPost.parseMeta(page)
        XCTAssertNil(meta["og:title"])
        XCTAssertNil(meta["og:description"], "no content attribute, no entry")
        XCTAssertEqual(meta["og:site_name"], "Some Site")
    }

    func testMetaScannerSurvivesBrokenMarkup() {
        XCTAssertEqual(SocialPost.parseMeta(""), [:])
        XCTAssertEqual(SocialPost.parseMeta("<meta"), [:])
        XCTAssertEqual(SocialPost.parseMeta(#"<meta property="og:title" content="never closed"#)["og:title"], "never closed")
        XCTAssertEqual(SocialPost.parseMeta("<<<>>> <meta = = ="), [:])
        XCTAssertEqual(SocialPost.parseMeta(#"<script>never closed <meta property="a" content="b">"#), [:])
    }

    func testMetaScannerReadsATagAfterHundredsOfKilobytesOfScript() {
        // Facebook's real pages are mostly script. The tags sit in the head, but
        // the scan must also cope with a big page where the tag comes last.
        let script = "<script type=\"application/json\">" + String(repeating: "{\"a\":\"<meta property=\\\"og:title\\\">\"},", count: 12_000) + "</script>"
        let page = "<html><head>" + script + #"<meta property="og:title" content="After the script">"# + "</head></html>"
        XCTAssertGreaterThan(page.utf8.count, 400_000)
        XCTAssertEqual(SocialPost.parseMeta(page)["og:title"], "After the script")
    }

    func testMetaScannerPrefersPropertyOverName() {
        let meta = SocialPost.parseMeta(#"<meta name="description" property="og:description" content="x">"#)
        XCTAssertEqual(meta["og:description"], "x")
        XCTAssertNil(meta["description"])
    }

    // MARK: - Entities

    func testEntityDecoding() {
        XCTAssertEqual(SocialPost.decodeEntities("a &amp; b &lt;c&gt; &quot;d&quot; &#39;e&#39;"), "a & b <c> \"d\" 'e'")
        XCTAssertEqual(SocialPost.decodeEntities("&#x2019;&#8217;&mdash;&hellip;"), "\u{2019}\u{2019}\u{2014}\u{2026}")
        XCTAssertEqual(SocialPost.decodeEntities("fish &amp chips; & more; &unknown; &#0; &#xD800;"), "fish &amp chips; & more; &unknown; &#0; &#xD800;")
        XCTAssertEqual(SocialPost.decodeEntities("no entities here"), "no entities here")
    }

    func testEntityDecodingIsASingleLeftToRightPass() {
        XCTAssertEqual(SocialPost.decodeEntities("&amp;lt;3"), "&lt;3")
        XCTAssertEqual(SocialPost.decodeEntities("&amp;amp;"), "&amp;")
    }

    // MARK: - Titles

    func testFirstLineTitle() {
        XCTAssertEqual(SocialPost.firstLineTitle("\n\nHello\nworld"), "Hello")
        XCTAssertEqual(SocialPost.firstLineTitle("  Hello  \r\n  world"), "Hello")
        XCTAssertEqual(SocialPost.firstLineTitle("One line"), "One line")
    }

    func testFirstLineTitleIsNilWhenThereIsNoText() {
        XCTAssertNil(SocialPost.firstLineTitle(""))
        XCTAssertNil(SocialPost.firstLineTitle("  \n \n\t"))
    }

    func testTitleTruncatesToOneHundredCharacters() {
        let long = String(repeating: "x", count: 300)
        let title = SocialPost.firstLineTitle(long)
        XCTAssertEqual(title?.count, 100)
        XCTAssertEqual(title?.hasSuffix("\u{2026}"), true)
        XCTAssertEqual(title, String(repeating: "x", count: 99) + "\u{2026}")
    }

    func testTitleOfExactlyTheLimitIsKept() {
        let exact = String(repeating: "y", count: 100)
        XCTAssertEqual(SocialPost.firstLineTitle(exact), exact)
        XCTAssertEqual(SocialPost.firstLineTitle(exact + "z")?.count, 100)
    }

    func testTitleCutDropsTrailingSpaceBeforeTheEllipsis() {
        let text = String(repeating: "a", count: 98) + " " + String(repeating: "b", count: 20)
        XCTAssertEqual(SocialPost.firstLineTitle(text), String(repeating: "a", count: 98) + "\u{2026}")
    }

    func testTitleCutNeverSplitsAnEmoji() {
        let text = String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", count: 120)   // family emoji, one character each
        let title = SocialPost.firstLineTitle(text)
        XCTAssertEqual(title?.count, 100)
        XCTAssertEqual(title?.dropLast(), Substring(String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", count: 99)))
    }

    // MARK: - X: embed feed text

    func testSyndicationTextExpandsLinksAndHonorsDisplayRange() {
        let data = json([
            "text": "Look at this https://t.co/abc https://t.co/img",
            "display_text_range": [0, 29],
            "entities": ["urls": [["url": "https://t.co/abc", "expanded_url": "https://example.com/a"]]],
            "mediaDetails": [["url": "https://t.co/img", "type": "photo"]]
        ])
        XCTAssertEqual(SocialPost.xText(fromSyndicationJSON: data), "Look at this https://example.com/a")
    }

    func testSyndicationTextRemovesTrailingMediaLinkWithoutARange() {
        let data = json([
            "text": "Fresh bread today https://t.co/pic",
            "mediaDetails": [["url": "https://t.co/pic", "type": "photo"]]
        ])
        XCTAssertEqual(SocialPost.xText(fromSyndicationJSON: data), "Fresh bread today")
    }

    func testSyndicationDisplayRangeCountsUnicodeScalarsNotUTF16Units() {
        let data = json([
            "text": "\u{1F600} hello https://t.co/xyz",
            "display_text_range": [0, 7]
        ])
        XCTAssertEqual(SocialPost.xText(fromSyndicationJSON: data), "\u{1F600} hello")
    }

    func testSyndicationDisplayRangeIsClamped() {
        let past = json(["text": "short", "display_text_range": [0, 500]])
        XCTAssertEqual(SocialPost.xText(fromSyndicationJSON: past), "short")
        let backwards = json(["text": "short", "display_text_range": [4, 2]])
        XCTAssertEqual(SocialPost.xText(fromSyndicationJSON: backwards), "")
        let negative = json(["text": "short", "display_text_range": [-3, 3]])
        XCTAssertEqual(SocialPost.xText(fromSyndicationJSON: negative), "sho")
    }

    func testSyndicationTextDecodesEntities() {
        let data = json(["text": "Salt &amp; pepper &lt;3"])
        XCTAssertEqual(SocialPost.xText(fromSyndicationJSON: data), "Salt & pepper <3")
    }

    func testSyndicationQuotedPostIsAppended() {
        let data = json(["text": "Hi", "quoted_tweet": ["text": "Original", "user": ["screen_name": "bobexample"]]])
        XCTAssertEqual(SocialPost.xText(fromSyndicationJSON: data), "Hi\n\nQuoted post by @bobexample: Original")
    }

    func testSyndicationQuotedPostWithoutAUserNamesSomeone() {
        let data = json(["text": "Hi", "quoted_tweet": ["text": "Original &amp; more"]])
        XCTAssertEqual(SocialPost.xText(fromSyndicationJSON: data), "Hi\n\nQuoted post by @someone: Original & more")
    }

    func testSyndicationEntityWithoutAnExpandedURLKeepsTheShortLink() {
        let data = json([
            "text": "see https://t.co/zzz",
            "entities": ["urls": [["url": "https://t.co/zzz"]]]
        ])
        XCTAssertEqual(SocialPost.xText(fromSyndicationJSON: data), "see https://t.co/zzz")
    }

    func testSyndicationWithoutTextIsNil() {
        XCTAssertNil(SocialPost.xText(fromSyndicationJSON: json(["tombstone": ["text": "gone"]])))
        XCTAssertNil(SocialPost.xText(fromSyndicationJSON: json(["text": NSNull()])))
        XCTAssertNil(SocialPost.xText(fromSyndicationJSON: Data("not json".utf8)))
        XCTAssertNil(SocialPost.xText(fromSyndicationJSON: Data()))
        XCTAssertNil(SocialPost.xText(fromSyndicationJSON: Data("[1,2]".utf8)))
    }

    func testSyndicationPostComposesTitleBodyAndVideoFlag() {
        let data = json(["text": "First line of the post\nSecond line", "video": ["variants": [["type": "video/mp4"]]]])
        let post = SocialPost.post(fromSyndicationJSON: data)
        XCTAssertEqual(post?.title, "First line of the post")
        XCTAssertEqual(post?.bodyMarkdown, "First line of the post\nSecond line")
        XCTAssertEqual(post?.isVideo, true)
    }

    func testSyndicationPostWithEmptyTextIsNil() {
        XCTAssertNil(SocialPost.post(fromSyndicationJSON: json(["text": "https://t.co/pic", "mediaDetails": [["url": "https://t.co/pic", "type": "video"]]])))
        XCTAssertNil(SocialPost.post(fromSyndicationJSON: json(["text": "   "])))
    }

    // MARK: - X: video detection

    func testXVideoDetection() {
        XCTAssertTrue(SocialPost.xIsVideo(fromSyndicationJSON: json(["text": "a", "video": ["durationMs": 1000]])))
        XCTAssertTrue(SocialPost.xIsVideo(fromSyndicationJSON: json(["text": "a", "mediaDetails": [["type": "video"]]])))
        XCTAssertTrue(SocialPost.xIsVideo(fromSyndicationJSON: json(["text": "a", "mediaDetails": [["type": "photo"], ["type": "animated_gif"]]])))
    }

    func testXNonVideoDetection() {
        XCTAssertFalse(SocialPost.xIsVideo(fromSyndicationJSON: json(["text": "a"])))
        XCTAssertFalse(SocialPost.xIsVideo(fromSyndicationJSON: json(["text": "a", "video": [String: Any]()])))
        XCTAssertFalse(SocialPost.xIsVideo(fromSyndicationJSON: json(["text": "a", "mediaDetails": [["type": "photo"]]])))
        XCTAssertFalse(SocialPost.xIsVideo(fromSyndicationJSON: Data("not json".utf8)))
    }

    // MARK: - X: oEmbed fallback

    func testOEmbedTextHandlesBreaksTagsAndEntities() {
        let data = json(["html": "<blockquote class=\"twitter-tweet\"><p lang=\"en\" dir=\"ltr\">Line a<br>Line b &amp; c <a href=\"https://t.co/x\">link</a></p>&mdash; Pat Example (@patexample) <a href=\"https://twitter.com/patexample/status/20\">March 3, 2026</a></blockquote>"])
        XCTAssertEqual(SocialPost.xText(fromOEmbedJSON: data), "Line a\nLine b & c link")
    }

    func testOEmbedTextHandlesSelfClosingAndUppercaseBreaks() {
        let data = json(["html": "<blockquote><p>One<BR/>Two<br />Three</p></blockquote>"])
        XCTAssertEqual(SocialPost.xText(fromOEmbedJSON: data), "One\nTwo\nThree")
    }

    func testOEmbedTextIsEmptyWithoutAParagraph() {
        XCTAssertEqual(SocialPost.xText(fromOEmbedJSON: json(["html": "<blockquote></blockquote>"])), "")
        XCTAssertEqual(SocialPost.xText(fromOEmbedJSON: json(["author_name": "Pat Example"])), "")
        XCTAssertEqual(SocialPost.xText(fromOEmbedJSON: Data("nope".utf8)), "")
    }

    func testOEmbedPostIsNeverFlaggedAsVideo() {
        let post = SocialPost.post(fromOEmbedJSON: json(["html": "<blockquote><p>Hello there</p></blockquote>"]))
        XCTAssertEqual(post?.title, "Hello there")
        XCTAssertEqual(post?.bodyMarkdown, "Hello there")
        XCTAssertEqual(post?.isVideo, false)
        XCTAssertNil(SocialPost.post(fromOEmbedJSON: json(["html": "<blockquote><p>  </p></blockquote>"])))
    }

    // MARK: - Video pages

    func testMetaVideoByOGType() {
        XCTAssertTrue(SocialPost.isVideoPage(meta: ["og:type": "video.other"], urls: []))
        XCTAssertTrue(SocialPost.isVideoPage(meta: ["og:type": "Video.Movie"], urls: []))
        XCTAssertFalse(SocialPost.isVideoPage(meta: ["og:type": "article"], urls: []))
    }

    func testMetaVideoByOGVideoTag() {
        XCTAssertTrue(SocialPost.isVideoPage(meta: ["og:video": "https://example.com/v.mp4"], urls: []))
        XCTAssertTrue(SocialPost.isVideoPage(meta: ["og:video:secure_url": "https://example.com/v.mp4"], urls: []))
        XCTAssertFalse(SocialPost.isVideoPage(meta: ["og:image": "https://example.com/p.jpg"], urls: []))
    }

    func testMetaVideoByAnyURL() {
        let share = url("https://www.facebook.com/share/p/ABC/")
        let reel = url("https://www.facebook.com/reel/1234567890/")
        XCTAssertFalse(SocialPost.isVideoPage(meta: [:], urls: [share]))
        XCTAssertTrue(SocialPost.isVideoPage(meta: [:], urls: [share, reel]), "a redirect or canonical link can show the video")
        XCTAssertTrue(SocialPost.isVideoPage(meta: [:], urls: [url("https://fb.watch/abc/")]))
    }

    // MARK: - Whole meta pages

    private func page(_ tags: String) -> String {
        "<html><head><title>x</title>\(tags)</head><body>ignored</body></html>"
    }

    func testFacebookVideoPage() {
        let html = page("""
        <meta property="og:type" content="video.other">\
        <meta property="og:title" content="12 reactions · 2 comments | New bakery hours start Monday.">\
        <meta property="og:description" content="New bakery hours start Mon...">\
        <meta property="og:url" content="https://www.facebook.com/reel/1234567890/">
        """)
        let post = SocialPost.post(
            fromMetaHTML: html, platform: .facebook,
            requestURL: url("https://www.facebook.com/share/v/ABC123/"), finalURL: nil)
        XCTAssertEqual(post?.title, "New bakery hours start Monday.")
        XCTAssertEqual(post?.bodyMarkdown, "New bakery hours start Monday.")
        XCTAssertEqual(post?.isVideo, true)
    }

    func testFacebookPhotoPostIsNotAVideo() {
        let html = page("""
        <meta property="og:type" content="article">\
        <meta property="og:title" content="3 reactions | Photos from the street fair.">\
        <meta property="og:url" content="https://www.facebook.com/somepage/posts/55">
        """)
        let post = SocialPost.post(
            fromMetaHTML: html, platform: .facebook,
            requestURL: url("https://www.facebook.com/share/p/ABC123/"),
            finalURL: url("https://www.facebook.com/somepage/posts/55"))
        XCTAssertEqual(post?.bodyMarkdown, "Photos from the street fair.")
        XCTAssertEqual(post?.isVideo, false)
    }

    func testFacebookShareLinkThatRedirectsToAReelIsAVideo() {
        let html = page(#"<meta property="og:title" content="Quick pasta tip.">"#)
        let post = SocialPost.post(
            fromMetaHTML: html, platform: .facebook,
            requestURL: url("https://www.facebook.com/share/p/ABC123/"),
            finalURL: url("https://www.facebook.com/reel/777/"))
        XCTAssertEqual(post?.isVideo, true)
    }

    func testLoginWallPageGivesNoPost() {
        let html = page("""
        <meta property="og:title" content="Log in or sign up to view">\
        <meta property="og:description" content="See posts, photos and more on Facebook.">
        """)
        XCTAssertNil(SocialPost.post(fromMetaHTML: html, platform: .facebook, requestURL: url("https://www.facebook.com/reel/1/"), finalURL: nil))
    }

    func testEmptyStubPageGivesNoPost() {
        XCTAssertNil(SocialPost.post(fromMetaHTML: "<html><body>Enable JavaScript</body></html>", platform: .facebook, requestURL: url("https://www.facebook.com/x"), finalURL: nil))
        XCTAssertNil(SocialPost.post(fromMetaHTML: "", platform: .threads, requestURL: url("https://www.threads.net/@a/post/B"), finalURL: nil))
    }

    func testInstagramPage() {
        let html = page(#"<meta property="og:title" content="Pat Example (@patexample) on Instagram: &quot;Sunset at the lake&quot;">"#)
        let post = SocialPost.post(
            fromMetaHTML: html, platform: .instagram,
            requestURL: url("https://www.instagram.com/reel/AbC/"), finalURL: nil)
        XCTAssertEqual(post?.title, "Sunset at the lake")
        XCTAssertEqual(post?.isVideo, true, "the page is a video; the service decides not to hand it off")
    }

    func testInstagramLoginPageGivesNoPost() {
        let html = page("""
        <meta property="og:title" content="Instagram">\
        <meta property="og:description" content="Create an account or log in to Instagram - share photos and videos with friends.">
        """)
        XCTAssertNil(SocialPost.post(fromMetaHTML: html, platform: .instagram, requestURL: url("https://www.instagram.com/p/AbC/"), finalURL: nil))
    }

    func testThreadsPage() {
        let html = page(#"<meta property="og:description" content="Hello from threads&#33;">"#)
        let post = SocialPost.post(
            fromMetaHTML: html, platform: .threads,
            requestURL: url("https://www.threads.net/@someone/post/B"), finalURL: nil)
        XCTAssertEqual(post?.bodyMarkdown, "Hello from threads!")
        XCTAssertEqual(post?.isVideo, false)
    }

    func testThreadsLoginPageGivesNoPost() {
        let html = page(#"<meta property="og:description" content="Join Threads to share ideas, ask questions, post random thoughts, find your people.">"#)
        XCTAssertNil(SocialPost.post(fromMetaHTML: html, platform: .threads, requestURL: url("https://www.threads.net/@a/post/B"), finalURL: nil))
    }

    func testLongPostTitleIsCutButBodyIsWhole() {
        let long = String(repeating: "word ", count: 60).trimmingCharacters(in: .whitespaces)
        let html = page(#"<meta property="og:title" content="\#(long)">"#)
        let post = SocialPost.post(fromMetaHTML: html, platform: .facebook, requestURL: url("https://www.facebook.com/somepage/posts/1"), finalURL: nil)
        XCTAssertEqual(post?.title?.count, 100)
        XCTAssertEqual(post?.bodyMarkdown, long)
    }
}
