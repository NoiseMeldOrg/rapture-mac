import XCTest
@testable import Rapture

/// Lenient-decode round-trips for the M3 handoff fields: pre-existing settings.json
/// and state.json files must load with both toggles off and no target IDs — the
/// handoff is a strict opt-in and older files must never flip it on.
final class HandoffSettingsDecodeTests: XCTestCase {

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

    // MARK: - Settings handoff fields

    func testHandoffFieldsDefaultOffWhenKeysAbsent() throws {
        let legacy = #"{"allowedHandles":[],"allowSMS":false,"launchAtLogin":true,"paused":false,"replyMode":"all","relayEnabled":true,"triageMode":"full"}"#
        let settings = try decoder().decode(Settings.self, from: Data(legacy.utf8))
        XCTAssertFalse(settings.remindersHandoffEnabled, "older settings.json must default Reminders handoff off")
        XCTAssertFalse(settings.calendarHandoffEnabled, "older settings.json must default Calendar handoff off")
        XCTAssertNil(settings.remindersListID)
        XCTAssertNil(settings.calendarID)
    }

    func testHandoffFieldsRoundTrip() throws {
        var settings = Settings()
        settings.remindersHandoffEnabled = true
        settings.calendarHandoffEnabled = true
        settings.remindersListID = "list-uuid-1"
        settings.calendarID = "cal-uuid-2"

        let data = try encoder().encode(settings)
        let reloaded = try decoder().decode(Settings.self, from: data)

        XCTAssertTrue(reloaded.remindersHandoffEnabled)
        XCTAssertTrue(reloaded.calendarHandoffEnabled)
        XCTAssertEqual(reloaded.remindersListID, "list-uuid-1")
        XCTAssertEqual(reloaded.calendarID, "cal-uuid-2")
    }

    // MARK: - PersistedState.handoffRecords

    func testHandoffRecordsDefaultWhenKeyAbsent() throws {
        let legacy = #"{"chatDbWatermark":42,"todayCount":3}"#
        let state = try decoder().decode(PersistedState.self, from: Data(legacy.utf8))
        XCTAssertEqual(state.handoffRecords, [])
    }

    func testHandoffRecordsRoundTrip() throws {
        var state = PersistedState()
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        state.handoffRecords = [HandoffEntry(fingerprint: "reminder|change the furnace filter|2026-07-15T13:00:00Z", createdAt: createdAt)]

        let data = try encoder().encode(state)
        let reloaded = try decoder().decode(PersistedState.self, from: data)

        XCTAssertEqual(reloaded.handoffRecords, [HandoffEntry(fingerprint: "reminder|change the furnace filter|2026-07-15T13:00:00Z", createdAt: createdAt)])
    }
}
