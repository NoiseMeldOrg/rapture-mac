import XCTest
@testable import Rapture

/// Lenient decoding for the M5 fields: pre-M5 settings.json/state.json files
/// load with enrichment off and an empty enriched-link ledger.
final class EnrichmentSettingsDecodeTests: XCTestCase {

    func testPreM5SettingsDecodeWithEnrichmentOff() throws {
        let json = """
        {"allowedHandles":[],"allowSMS":false,"launchAtLogin":true,"paused":false,
         "replyMode":"all","triageMode":"full","aiTriageEnabled":true}
        """
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertFalse(settings.linkEnrichmentEnabled)
        XCTAssertTrue(settings.aiTriageEnabled, "existing fields survive")
    }

    func testEnrichmentEnabledRoundTrips() throws {
        var settings = Settings()
        settings.linkEnrichmentEnabled = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertTrue(decoded.linkEnrichmentEnabled)
    }

    func testDefaultIsOff() {
        XCTAssertFalse(Settings().linkEnrichmentEnabled)
    }

    // MARK: - Auto-transcribe Facebook and X videos

    func testSettingsWithoutTheSocialVideosKeyDecodeWithItOn() throws {
        let json = """
        {"allowedHandles":[],"allowSMS":false,"launchAtLogin":true,"paused":false,
         "replyMode":"all","triageMode":"full","linkEnrichmentEnabled":true,
         "autoTranscribeYouTube":false,"transcriptPipelineFolder":"/Volumes/X/Pipeline"}
        """
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertTrue(settings.autoTranscribeSocialVideos, "absent key decodes to the default, on")
        XCTAssertFalse(settings.autoTranscribeYouTube, "the YouTube setting is read on its own")
        XCTAssertEqual(settings.transcriptPipelineFolder, "/Volumes/X/Pipeline", "existing fields survive")
        XCTAssertTrue(settings.linkEnrichmentEnabled, "existing fields survive")
    }

    func testSettingsWithTheSocialVideosKeyOffDecodeOff() throws {
        let json = """
        {"autoTranscribeSocialVideos":false,"autoTranscribeYouTube":true}
        """
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertFalse(settings.autoTranscribeSocialVideos)
        XCTAssertTrue(settings.autoTranscribeYouTube)
    }

    func testSocialVideosSettingRoundTrips() throws {
        var settings = Settings()
        settings.autoTranscribeSocialVideos = false
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(decoded.autoTranscribeSocialVideos)
        XCTAssertTrue(decoded.autoTranscribeYouTube, "the two toggles do not move together")
    }

    func testSocialVideosSettingDefaultsOn() {
        XCTAssertTrue(Settings().autoTranscribeSocialVideos)
    }

    // MARK: - Enriched link ledger

    func testEnrichedLinkRecordsDefaultWhenKeyAbsent() throws {
        let json = """
        {"chatDbWatermark":42,"todayCount":3}
        """
        let state = try JSONDecoder().decode(PersistedState.self, from: Data(json.utf8))
        XCTAssertEqual(state.enrichedLinkRecords, [])
        XCTAssertEqual(state.chatDbWatermark, 42, "existing fields survive")
    }

    func testEnrichedLinkEntryWithoutTheVideoFlagDecodesAsNil() throws {
        // An entry written before the flag existed.
        let json = """
        {"enrichedLinkRecords":[
          {"fingerprint":"url:https://example.com/a","artifactRelativePath":"Links/Media/A.md",
           "title":"A","fetchedAt":"2026-07-13T12:00:00Z"}
        ]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(PersistedState.self, from: Data(json.utf8))
        XCTAssertNil(state.enrichedLinkRecords.first?.isVideo)
        XCTAssertEqual(state.enrichedLinkRecords.first?.title, "A")
    }

    func testEnrichedLinkVideoFlagRoundTrips() throws {
        var state = PersistedState()
        state.enrichedLinkRecords = [
            EnrichedLinkEntry(
                fingerprint: "url:https://www.facebook.com/reel/1",
                artifactRelativePath: "Links/Media/2026-11-23 Post.md",
                title: "Post",
                fetchedAt: Date(timeIntervalSince1970: 1_780_000_000),
                isVideo: true)
        ]
        let decoded = try JSONDecoder().decode(PersistedState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.enrichedLinkRecords, state.enrichedLinkRecords)
        XCTAssertEqual(decoded.enrichedLinkRecords.first?.isVideo, true)
    }

    func testEnrichedLinkRecordsRoundTrip() throws {
        var state = PersistedState()
        state.enrichedLinkRecords = [
            EnrichedLinkEntry(
                fingerprint: "yt:dQw4w9WgXcQ",
                artifactRelativePath: "Links/Media/2026-07-13 Some Video.md",
                title: "Some Video",
                fetchedAt: Date(timeIntervalSince1970: 1_780_000_000)
            )
        ]
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(PersistedState.self, from: data)
        XCTAssertEqual(decoded.enrichedLinkRecords, state.enrichedLinkRecords)
    }
}
