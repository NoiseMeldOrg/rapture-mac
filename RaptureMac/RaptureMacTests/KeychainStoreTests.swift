import XCTest
@testable import Rapture

/// One real round trip against the login keychain, under a dedicated
/// test-only service that is cleaned up in teardown. Generic-password items in
/// the app's own keychain prompt nothing and touch no network/TCC. Everything
/// else in the suite uses `FakeCredentialStore`.
@MainActor
final class KeychainStoreTests: XCTestCase {

    private let testService = "noisemeld.RaptureMac.tests"
    private var store: KeychainStore!

    override func setUp() async throws {
        store = KeychainStore(service: testService)
        try store.setAnthropicAPIKey(nil)
    }

    override func tearDown() async throws {
        try? store.setAnthropicAPIKey(nil)
        store = nil
    }

    func testRoundTripSetReadReplaceDelete() throws {
        XCTAssertNil(store.anthropicAPIKey())

        try store.setAnthropicAPIKey("sk-first")
        XCTAssertEqual(store.anthropicAPIKey(), "sk-first")

        // Replace (delete-then-add upsert).
        try store.setAnthropicAPIKey("sk-second")
        XCTAssertEqual(store.anthropicAPIKey(), "sk-second")

        // A fresh instance (no cache) reads the same item.
        let fresh = KeychainStore(service: testService)
        XCTAssertEqual(fresh.anthropicAPIKey(), "sk-second")

        // Delete via nil; empty string also deletes.
        try store.setAnthropicAPIKey(nil)
        XCTAssertNil(store.anthropicAPIKey())
        XCTAssertNil(KeychainStore(service: testService).anthropicAPIKey())
    }

    func testEmptyStringDeletes() throws {
        try store.setAnthropicAPIKey("sk-x")
        try store.setAnthropicAPIKey("")
        XCTAssertNil(store.anthropicAPIKey())
    }

    func testDebugServiceIsIsolatedFromRelease() {
        // The DEBUG-conditional service name mirrors the app-support container
        // isolation: a Debug build must never read the installed app's key.
        #if DEBUG
        XCTAssertEqual(KeychainStore.service, "noisemeld.RaptureMac.debug")
        #else
        XCTAssertEqual(KeychainStore.service, "noisemeld.RaptureMac")
        #endif
    }
}
