import XCTest
@testable import Rapture

/// Lenient-decode round-trips for the relay fields: pre-existing settings.json and
/// state.json files (written before this feature) must load with the new defaults.
final class RelaySettingsDecodeTests: XCTestCase {

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

    // MARK: - Settings.relayEnabled

    func testRelayEnabledDefaultsTrueWhenKeyAbsent() throws {
        let legacy = #"{"allowedHandles":[],"allowSMS":false,"launchAtLogin":true,"paused":false,"replyMode":"all"}"#
        let settings = try decoder().decode(Settings.self, from: Data(legacy.utf8))
        XCTAssertTrue(settings.relayEnabled, "older settings.json must default to relay on")
    }

    func testRelayEnabledFalseRoundTrips() throws {
        var settings = Settings()
        settings.relayEnabled = false
        let data = try encoder().encode(settings)
        let reloaded = try decoder().decode(Settings.self, from: data)
        XCTAssertFalse(reloaded.relayEnabled)
    }

    // MARK: - PersistedState.relayFiledRecords

    func testRelayFiledRecordsDefaultEmptyWhenKeyAbsent() throws {
        let legacy = #"{"chatDbWatermark":42,"todayCount":3}"#
        let state = try decoder().decode(PersistedState.self, from: Data(legacy.utf8))
        XCTAssertEqual(state.relayFiledRecords, [])
        XCTAssertEqual(state.chatDbWatermark, 42)
    }

    func testRelayFiledRecordsRoundTrip() throws {
        var state = PersistedState()
        let filedAt = Date(timeIntervalSince1970: 1_800_000_000)
        state.relayFiledRecords = [RelayFiledEntry(relayFilename: "2026-07-06T15-14-42Z Grocery Ideas.txt", filedAt: filedAt)]

        let data = try encoder().encode(state)
        let reloaded = try decoder().decode(PersistedState.self, from: data)

        XCTAssertEqual(reloaded.relayFiledRecords.count, 1)
        XCTAssertEqual(reloaded.relayFiledRecords.first?.relayFilename, "2026-07-06T15-14-42Z Grocery Ideas.txt")
        XCTAssertEqual(reloaded.relayFiledRecords.first?.filedAt, filedAt)
    }
}
