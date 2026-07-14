import XCTest
@testable import Rapture

/// Lenient decoding for the M4 settings field: pre-M4 settings.json files load
/// with AI off, and the key never appears in settings (it lives in the
/// Keychain).
final class AISettingsDecodeTests: XCTestCase {

    func testPreM4SettingsDecodeWithAIOff() throws {
        let json = """
        {"allowedHandles":[],"allowSMS":false,"launchAtLogin":true,"paused":false,
         "replyMode":"all","triageMode":"full","remindersHandoffEnabled":true}
        """
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertFalse(settings.aiTriageEnabled)
        XCTAssertTrue(settings.remindersHandoffEnabled, "existing fields survive")
    }

    func testAIEnabledRoundTrips() throws {
        var settings = Settings()
        settings.aiTriageEnabled = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertTrue(decoded.aiTriageEnabled)
    }

    func testDefaultIsOff() {
        XCTAssertFalse(Settings().aiTriageEnabled)
    }

    func testNoAPIKeyFieldInEncodedSettings() throws {
        // The Anthropic key must never ride in settings.json — Keychain only.
        let data = try JSONEncoder().encode(Settings())
        let text = String(decoding: data, as: UTF8.self).lowercased()
        XCTAssertFalse(text.contains("apikey"))
        XCTAssertFalse(text.contains("anthropic"))
    }
}
