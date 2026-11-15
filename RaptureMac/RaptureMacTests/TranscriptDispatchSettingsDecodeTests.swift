import XCTest
@testable import Rapture

/// Lenient decoding for the transcript-dispatch fields: pre-feature
/// settings.json/state.json files load with the toggle ON (opt-out, like
/// relayEnabled), the pipeline folder NOT set (so the feature is off until
/// the user chooses one), and an empty dispatch ledger; an unknown status raw
/// value degrades instead of nuking state.json. Mirrors
/// `EnrichmentSettingsDecodeTests`.
final class TranscriptDispatchSettingsDecodeTests: XCTestCase {

    func testPreFeatureSettingsDecodeWithAutoTranscribeOn() throws {
        let json = """
        {"allowedHandles":[],"allowSMS":false,"launchAtLogin":true,"paused":false,
         "replyMode":"all","triageMode":"full","linkEnrichmentEnabled":true}
        """
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertTrue(settings.autoTranscribeYouTube, "absent key → default on (opt-out)")
        XCTAssertTrue(settings.linkEnrichmentEnabled, "existing fields survive")
    }

    func testAutoTranscribeOffRoundTrips() throws {
        var settings = Settings()
        settings.autoTranscribeYouTube = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertFalse(decoded.autoTranscribeYouTube)
    }

    func testDefaultIsOn() {
        XCTAssertTrue(Settings().autoTranscribeYouTube)
    }

    // MARK: - Pipeline folder

    func testPreFeatureSettingsDecodeWithPipelineFolderNotSet() throws {
        // A settings.json from before the key existed: the folder is NOT set
        // (no default path, no migration), and nothing else resets.
        let json = """
        {"allowedHandles":[],"allowSMS":false,"launchAtLogin":true,"paused":false,
         "replyMode":"all","triageMode":"full","linkEnrichmentEnabled":true,
         "autoTranscribeYouTube":true}
        """
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertNil(settings.transcriptPipelineFolder, "absent key → not set → feature off")
        XCTAssertTrue(settings.autoTranscribeYouTube, "existing fields survive")
        XCTAssertTrue(settings.linkEnrichmentEnabled, "existing fields survive")
    }

    func testPipelineFolderDefaultIsNotSet() {
        XCTAssertNil(Settings().transcriptPipelineFolder, "a new install has no folder")
    }

    func testPipelineFolderRoundTrips() throws {
        var settings = Settings()
        settings.transcriptPipelineFolder = "/Volumes/X/My Pipeline"
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(decoded.transcriptPipelineFolder, "/Volumes/X/My Pipeline")
    }

    func testPipelineFolderNotSetRoundTripsAsNotSet() throws {
        let data = try JSONEncoder().encode(Settings())
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertNil(decoded.transcriptPipelineFolder)
    }

    func testPipelineFolderExplicitNullAndHandEditedTildeDecode() throws {
        let nullJSON = """
        {"transcriptPipelineFolder":null}
        """
        XCTAssertNil(try JSONDecoder().decode(Settings.self, from: Data(nullJSON.utf8)).transcriptPipelineFolder)

        // Stored verbatim; the "~" is expanded only when the folder is read.
        let tildeJSON = """
        {"transcriptPipelineFolder":"~/some/pipeline"}
        """
        let settings = try JSONDecoder().decode(Settings.self, from: Data(tildeJSON.utf8))
        XCTAssertEqual(settings.transcriptPipelineFolder, "~/some/pipeline")
    }

    func testDispatchRecordsDefaultWhenKeyAbsent() throws {
        let json = """
        {"chatDbWatermark":42,"todayCount":3}
        """
        let state = try JSONDecoder().decode(PersistedState.self, from: Data(json.utf8))
        XCTAssertEqual(state.transcriptDispatchRecords, [])
        XCTAssertEqual(state.chatDbWatermark, 42, "existing fields survive")
    }

    func testDispatchRecordsRoundTrip() throws {
        var state = PersistedState()
        state.transcriptDispatchRecords = [
            TranscriptDispatchEntry(
                fingerprint: "yt:JGB-D1xd400",
                url: "https://youtu.be/JGB-D1xd400",
                noteRelativePath: "Links/2026-08-31 Some Video.md",
                status: .dispatched,
                createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                dispatchedAt: Date(timeIntervalSince1970: 1_800_000_060),
                attempts: 1,
                lastError: nil
            )
        ]
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(PersistedState.self, from: data)
        XCTAssertEqual(decoded.transcriptDispatchRecords, state.transcriptDispatchRecords)
    }

    func testUnknownStatusDecodesLenientlyInsteadOfThrowing() throws {
        // A newer build's status value (or a hand edit) must not reset ALL of
        // state.json — one throwing element would, via StateStore's nil fallback.
        let json = """
        {"transcriptDispatchRecords":[
          {"fingerprint":"yt:abc","url":"u","noteRelativePath":"Links/A.md",
           "status":"somethingNew","createdAt":"2026-08-31T12:00:00Z","attempts":0}
        ]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(PersistedState.self, from: Data(json.utf8))
        XCTAssertEqual(state.transcriptDispatchRecords.first?.status, .failed)
    }
}
