import XCTest
@testable import Rapture

/// Lenient-decode round-trips for the triage fields: pre-existing settings.json and
/// state.json files (written before this feature) must load with the new defaults —
/// notably `triageMode == .full`, which is what flips updaters onto triage by default.
final class TriageSettingsDecodeTests: XCTestCase {

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    // MARK: - Settings.triageMode

    func testTriageModeDefaultsFullWhenKeyAbsent() throws {
        let legacy = #"{"allowedHandles":[],"allowSMS":false,"launchAtLogin":true,"paused":false,"replyMode":"all","relayEnabled":true}"#
        let settings = try decoder().decode(Settings.self, from: Data(legacy.utf8))
        XCTAssertEqual(settings.triageMode, .full, "older settings.json must default to full triage")
    }

    func testTriageModeRawRoundTrips() throws {
        var settings = Settings()
        settings.triageMode = .raw
        let data = try encoder().encode(settings)
        let reloaded = try decoder().decode(Settings.self, from: data)
        XCTAssertEqual(reloaded.triageMode, .raw)
    }

    func testUnknownTriageModeValueDegradesToFullWithoutResettingSettings() throws {
        // A newer build's enum case (or a hand-edit) must not throw: a throw here
        // would nil out the whole Settings load and silently reset every preference.
        let corrupted = #"{"allowedHandles":["+15551234567"],"triageMode":"bogus"}"#
        let settings = try decoder().decode(Settings.self, from: Data(corrupted.utf8))
        XCTAssertEqual(settings.triageMode, .full)
        XCTAssertEqual(settings.allowedHandles, ["+15551234567"], "other settings survive an unknown triageMode")
    }

    // MARK: - PersistedState triage fields

    func testTriagedRecordsAndIntroDefaultWhenKeysAbsent() throws {
        let legacy = #"{"chatDbWatermark":42,"todayCount":3}"#
        let state = try decoder().decode(PersistedState.self, from: Data(legacy.utf8))
        XCTAssertEqual(state.triagedRecords, [])
        XCTAssertFalse(state.triageIntroShown)
        XCTAssertEqual(state.chatDbWatermark, 42)
    }

    func testTriagedRecordsRoundTrip() throws {
        var state = PersistedState()
        let triagedAt = Date(timeIntervalSince1970: 1_800_000_000)
        state.triagedRecords = [TriagedEntry(
            sourceFilename: "2026-07-06T15-14-42Z.txt",
            contentHash: "abc123",
            mdRelativePath: "Notes/2026-07-06 Grocery ideas.md",
            triagedAt: triagedAt
        )]
        state.triageIntroShown = true

        let data = try encoder().encode(state)
        let reloaded = try decoder().decode(PersistedState.self, from: data)

        XCTAssertEqual(reloaded.triagedRecords.count, 1)
        XCTAssertEqual(reloaded.triagedRecords.first?.sourceFilename, "2026-07-06T15-14-42Z.txt")
        XCTAssertEqual(reloaded.triagedRecords.first?.contentHash, "abc123")
        XCTAssertEqual(reloaded.triagedRecords.first?.mdRelativePath, "Notes/2026-07-06 Grocery ideas.md")
        XCTAssertEqual(reloaded.triagedRecords.first?.triagedAt, triagedAt)
        XCTAssertTrue(reloaded.triageIntroShown)
    }
}
