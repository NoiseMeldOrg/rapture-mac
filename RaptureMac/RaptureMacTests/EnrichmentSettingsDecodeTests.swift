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

    func testEnrichedLinkRecordsDefaultWhenKeyAbsent() throws {
        let json = """
        {"chatDbWatermark":42,"todayCount":3}
        """
        let state = try JSONDecoder().decode(PersistedState.self, from: Data(json.utf8))
        XCTAssertEqual(state.enrichedLinkRecords, [])
        XCTAssertEqual(state.chatDbWatermark, 42, "existing fields survive")
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
