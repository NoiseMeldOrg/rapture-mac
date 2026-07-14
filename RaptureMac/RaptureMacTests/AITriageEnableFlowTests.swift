import XCTest
@testable import Rapture

/// The persist-on-success rule for the AI toggle: it may only turn ON when an
/// engine would actually run; otherwise it stays off with an honest reason.
@MainActor
final class AITriageEnableFlowTests: XCTestCase {

    private var support: URL!
    private var appState: AppState!
    private var credentials: FakeCredentialStore!

    override func setUpWithError() throws {
        support = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-enable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        credentials = FakeCredentialStore()
        appState = AppState(supportDirectory: support, credentials: credentials)
    }

    override func tearDownWithError() throws {
        if let support {
            try? FileManager.default.removeItem(at: support)
        }
    }

    private func makeService(appleAvailable: Bool) -> AITriageService {
        let apple = FakeAITriageEngine(kind: .apple)
        apple.availabilityResult = appleAvailable
            ? .available
            : .unavailable(reason: "Apple Intelligence is turned off in System Settings")
        return AITriageService(
            appState: appState,
            appleEngine: apple,
            anthropicEngine: FakeAITriageEngine(kind: .anthropic)
        )
    }

    func testEnableSucceedsWithAppleEngine() {
        let result = AITriageEnableFlow.enable(service: makeService(appleAvailable: true))
        XCTAssertTrue(result.enabled)
        XCTAssertEqual(result.status, .active(.apple))
        XCTAssertNil(result.error)
    }

    func testEnableSucceedsWithKeyWhenAppleUnavailable() {
        credentials.key = "sk-x"
        let result = AITriageEnableFlow.enable(service: makeService(appleAvailable: false))
        XCTAssertTrue(result.enabled)
        XCTAssertEqual(result.status, .active(.anthropic))
    }

    func testEnableRefusesWithNoEngineAndExplains() {
        let result = AITriageEnableFlow.enable(service: makeService(appleAvailable: false))
        XCTAssertFalse(result.enabled)
        guard case .unavailable(let reason) = result.status else { return XCTFail("expected unavailable") }
        XCTAssertTrue(reason.contains("no Anthropic API key"))
        XCTAssertTrue(result.error?.contains("Captures keep filing without AI") == true)
    }
}
