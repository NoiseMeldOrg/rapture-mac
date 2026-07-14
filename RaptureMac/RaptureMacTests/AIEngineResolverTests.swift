import XCTest
@testable import Rapture

/// Truth table for engine resolution: Apple first, else BYO key, else an
/// honest reason.
final class AIEngineResolverTests: XCTestCase {

    func testAppleWinsWhenAvailable() {
        // Even with a key present — on-device is private and free.
        XCTAssertEqual(
            AIEngineResolver.resolve(appleAvailable: true, appleUnavailableReason: nil, hasAPIKey: true, keyRejected: false),
            .apple
        )
        XCTAssertEqual(
            AIEngineResolver.resolve(appleAvailable: true, appleUnavailableReason: nil, hasAPIKey: false, keyRejected: false),
            .apple
        )
    }

    func testAnthropicWhenAppleUnavailableAndKeyPresent() {
        XCTAssertEqual(
            AIEngineResolver.resolve(
                appleAvailable: false, appleUnavailableReason: "Apple Intelligence is turned off in System Settings",
                hasAPIKey: true, keyRejected: false
            ),
            .anthropic
        )
    }

    func testNoneWhenNoKeyReasonNamesBoth() {
        let resolution = AIEngineResolver.resolve(
            appleAvailable: false, appleUnavailableReason: "This Mac doesn't support Apple Intelligence",
            hasAPIKey: false, keyRejected: false
        )
        guard case .none(let reason) = resolution else { return XCTFail("expected .none") }
        XCTAssertTrue(reason.contains("This Mac doesn't support Apple Intelligence"))
        XCTAssertTrue(reason.contains("no Anthropic API key is set"))
    }

    func testRejectedKeyBlocksAnthropic() {
        let resolution = AIEngineResolver.resolve(
            appleAvailable: false, appleUnavailableReason: "Apple Intelligence is turned off in System Settings",
            hasAPIKey: true, keyRejected: true
        )
        guard case .none(let reason) = resolution else { return XCTFail("expected .none") }
        XCTAssertTrue(reason.contains("rejected"))
    }
}
