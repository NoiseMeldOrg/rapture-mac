import XCTest
@testable import Rapture

/// The two real engines are front-guarded on XCTest: constructing them is
/// inert and every entry reports unavailable/throws under the hosted test
/// bundle — the suite can never touch the system model or the network.
@MainActor
final class AIEngineGuardTests: XCTestCase {

    func testAppleEngineInertUnderTests() async {
        let engine = AppleFoundationEngine()
        guard case .unavailable = engine.availability() else {
            return XCTFail("Apple engine must report unavailable under XCTest")
        }
        do {
            _ = try await engine.analyze(text: "hello", capturedAt: Date(), timeZone: .current)
            XCTFail("Apple engine must throw under XCTest")
        } catch {
            XCTAssertEqual(error as? AIEngineError, .unavailable)
        }
    }

    func testAnthropicEngineInertUnderTestsEvenWithKey() async {
        let engine = AnthropicEngine(credentials: FakeCredentialStore(key: "sk-present"))
        guard case .unavailable = engine.availability() else {
            return XCTFail("Anthropic engine must report unavailable under XCTest")
        }
        do {
            _ = try await engine.analyze(text: "hello", capturedAt: Date(), timeZone: .current)
            XCTFail("Anthropic engine must throw under XCTest — zero network from the suite")
        } catch {
            XCTAssertEqual(error as? AIEngineError, .unavailable)
        }
    }
}
