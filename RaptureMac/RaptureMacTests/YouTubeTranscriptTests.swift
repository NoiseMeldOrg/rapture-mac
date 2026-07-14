import XCTest
@testable import Rapture

/// Golden tests for the pure caption parsers against inline fixtures shaped
/// like the real endpoints' payloads.
final class YouTubeTranscriptTests: XCTestCase {

    // MARK: - Watch-page extraction

    func testExtractsPlayerResponseFromWatchHTML() throws {
        let html = #"""
        <html><head><script>var x = 1;</script></head><body>
        <script>var ytInitialPlayerResponse = {"captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[{"baseUrl":"https://www.youtube.com/api/timedtext?v=abc","languageCode":"en","kind":"asr"}]}},"videoDetails":{"title":"T \"quoted\" {brace}"}};var after = 2;</script>
        </body></html>
        """#
        let data = try XCTUnwrap(YouTubeTranscript.extractPlayerResponseJSON(fromWatchHTML: html))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["captions"], "extracted a parseable, brace-balanced object")
    }

    func testBraceBalancingSurvivesStringsWithBracesAndEscapes() throws {
        let html = #"ytInitialPlayerResponse = {"a":"open { and close } and \" escaped","b":{"c":1}}; rest"#
        let data = try XCTUnwrap(YouTubeTranscript.extractPlayerResponseJSON(fromWatchHTML: html))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["a"] as? String, "open { and close } and \" escaped")
    }

    func testMissingMarkerReturnsNil() {
        XCTAssertNil(YouTubeTranscript.extractPlayerResponseJSON(fromWatchHTML: "<html>no player here</html>"))
    }

    // MARK: - Caption tracks

    func testParsesCaptionTracks() {
        let json = #"""
        {"captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[
          {"baseUrl":"https://yt/tt?lang=de","languageCode":"de"},
          {"baseUrl":"https://yt/tt?lang=en-asr","languageCode":"en","kind":"asr"},
          {"baseUrl":"https://yt/tt?lang=en","languageCode":"en-US"}
        ]}}}
        """#
        let tracks = YouTubeTranscript.captionTracks(fromPlayerResponse: Data(json.utf8))
        XCTAssertEqual(tracks.count, 3)
        XCTAssertEqual(tracks[0].languageCode, "de")
        XCTAssertEqual(tracks[1].kind, "asr")
    }

    func testNoCaptionsSectionYieldsEmpty() {
        XCTAssertEqual(YouTubeTranscript.captionTracks(fromPlayerResponse: Data(#"{"videoDetails":{}}"#.utf8)), [])
        XCTAssertEqual(YouTubeTranscript.captionTracks(fromPlayerResponse: Data("garbage".utf8)), [])
    }

    func testTrackPreferenceManualEnglishOverASROverFirst() {
        let de = YouTubeTranscript.CaptionTrack(baseUrl: "u1", languageCode: "de", kind: nil)
        let enASR = YouTubeTranscript.CaptionTrack(baseUrl: "u2", languageCode: "en", kind: "asr")
        let enManual = YouTubeTranscript.CaptionTrack(baseUrl: "u3", languageCode: "en-US", kind: nil)

        XCTAssertEqual(YouTubeTranscript.pickTrack([de, enASR, enManual])?.baseUrl, "u3")
        XCTAssertEqual(YouTubeTranscript.pickTrack([de, enASR])?.baseUrl, "u2")
        XCTAssertEqual(YouTubeTranscript.pickTrack([de])?.baseUrl, "u1")
        XCTAssertNil(YouTubeTranscript.pickTrack([]))
    }

    // MARK: - json3 → plain paragraphs

    func testJoinsSegmentsIntoFlowingParagraphs() {
        let json = #"""
        {"events":[
          {"tStartMs":0,"segs":[{"utf8":"Hello"},{"utf8":" there"}]},
          {"tStartMs":1200,"segs":[{"utf8":"and welcome.\n"}]},
          {"tStartMs":9000,"segs":[{"utf8":"After a long pause."}]}
        ]}
        """#
        XCTAssertEqual(
            YouTubeTranscript.transcriptMarkdown(fromJSON3: Data(json.utf8)),
            "Hello there and welcome.\n\nAfter a long pause.")
    }

    func testEventsWithoutSegsAreSkipped() {
        let json = #"""
        {"events":[
          {"tStartMs":0,"wsWinId":1},
          {"tStartMs":100,"segs":[{"utf8":"Only real text survives."}]}
        ]}
        """#
        XCTAssertEqual(
            YouTubeTranscript.transcriptMarkdown(fromJSON3: Data(json.utf8)),
            "Only real text survives.")
    }

    func testEmptyPayloadYieldsNil() {
        XCTAssertNil(YouTubeTranscript.transcriptMarkdown(fromJSON3: Data(#"{"events":[]}"#.utf8)))
        XCTAssertNil(YouTubeTranscript.transcriptMarkdown(fromJSON3: Data("nope".utf8)))
    }

    // MARK: - Innertube + oEmbed

    func testInnertubeBodyCarriesVideoIDAndIOSClient() throws {
        let body = YouTubeTranscript.innertubeRequestBody(videoID: "dQw4w9WgXcQ")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["videoId"] as? String, "dQw4w9WgXcQ")
        let context = try XCTUnwrap(object["context"] as? [String: Any])
        let client = try XCTUnwrap(context["client"] as? [String: Any])
        // The iOS client is the one whose caption URLs serve real bodies (the
        // WEB client returns UNPLAYABLE with zero tracks — verified live).
        XCTAssertEqual(client["clientName"] as? String, "IOS")
        XCTAssertEqual(client["clientVersion"] as? String, YouTubeTranscript.innertubeClientVersion)
    }

    func testOEmbedTitle() {
        XCTAssertEqual(
            YouTubeTranscript.title(fromOEmbedJSON: Data(#"{"title":"Real Video Title","author_name":"x"}"#.utf8)),
            "Real Video Title")
        XCTAssertNil(YouTubeTranscript.title(fromOEmbedJSON: Data(#"{"title":"  "}"#.utf8)))
        XCTAssertNil(YouTubeTranscript.title(fromOEmbedJSON: Data("garbage".utf8)))
    }
}
