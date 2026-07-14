import XCTest
@testable import Rapture

/// The AI manager: toggle gate, engine resolution, timeout race, every failure
/// mode → nil (deterministic fallback), cooldown, and the 401 latch. All with
/// fakes — no model, no network, no keychain.
@MainActor
final class AITriageServiceTests: XCTestCase {

    /// Sendable clock box so the service's @Sendable clock closure can read a
    /// value the (MainActor) test mutates. Single-threaded in practice.
    private final class ClockBox: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private let fm = FileManager.default
    private var support: URL!
    private var appState: AppState!
    private var credentials: FakeCredentialStore!
    private var clockBox: ClockBox!
    private var now: Date { clockBox.now }

    override func setUpWithError() throws {
        support = fm.temporaryDirectory.appendingPathComponent("ai-service-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        credentials = FakeCredentialStore()
        appState = AppState(supportDirectory: support, credentials: credentials)
        clockBox = ClockBox()
    }

    override func tearDownWithError() throws {
        if let support, fm.fileExists(atPath: support.path) {
            try fm.removeItem(at: support)
        }
    }

    private func makeService(
        apple: FakeAITriageEngine? = nil,
        anthropic: FakeAITriageEngine? = nil,
        timeout: TimeInterval = 5
    ) -> AITriageService {
        AITriageService(
            appState: appState,
            appleEngine: apple,
            anthropicEngine: anthropic,
            clock: { [clockBox] in clockBox!.now },
            timeZoneProvider: { TimeZone(identifier: "America/New_York")! },
            timeout: timeout
        )
    }

    private func enableAI() {
        appState.settings.update { $0.aiTriageEnabled = true }
    }

    private var goodDraft: AIEngineDraft {
        AIEngineDraft(classification: "task", title: "Buy milk", formattedBody: nil, handoffs: [])
    }

    // MARK: - Toggle gate

    func testToggleOffReturnsNilWithZeroEngineContact() async {
        let apple = FakeAITriageEngine(kind: .apple, behavior: .draft(goodDraft))
        let service = makeService(apple: apple)

        let result = await service.analyze(text: "buy milk", capturedAt: now)

        XCTAssertNil(result)
        XCTAssertTrue(apple.analyzeCalls.isEmpty)
        XCTAssertEqual(appState.aiEngineStatus, .off)
    }

    func testEmptyTextReturnsNilWithZeroEngineContact() async {
        enableAI()
        let apple = FakeAITriageEngine(kind: .apple, behavior: .draft(goodDraft))
        let service = makeService(apple: apple)

        let result = await service.analyze(text: "   \n", capturedAt: now)

        XCTAssertNil(result)
        XCTAssertTrue(apple.analyzeCalls.isEmpty)
    }

    // MARK: - Resolution

    func testAppleEngineWinsWhenAvailable() async {
        enableAI()
        credentials.key = "sk-x"
        let apple = FakeAITriageEngine(kind: .apple, behavior: .draft(goodDraft))
        let anthropic = FakeAITriageEngine(kind: .anthropic, behavior: .draft(goodDraft))
        let service = makeService(apple: apple, anthropic: anthropic)

        let result = await service.analyze(text: "buy milk at the store", capturedAt: now)

        XCTAssertEqual(result?.classification, .task)
        XCTAssertEqual(apple.analyzeCalls.count, 1)
        XCTAssertTrue(anthropic.analyzeCalls.isEmpty)
        XCTAssertEqual(appState.aiEngineStatus, .active(.apple))
    }

    func testFallsThroughToAnthropicWhenAppleUnavailable() async {
        enableAI()
        credentials.key = "sk-x"
        let apple = FakeAITriageEngine(kind: .apple, behavior: .draft(goodDraft))
        apple.availabilityResult = .unavailable(reason: "Apple Intelligence is turned off in System Settings")
        let anthropic = FakeAITriageEngine(kind: .anthropic, behavior: .draft(goodDraft))
        let service = makeService(apple: apple, anthropic: anthropic)

        let result = await service.analyze(text: "buy milk at the store", capturedAt: now)

        XCTAssertNotNil(result)
        XCTAssertTrue(apple.analyzeCalls.isEmpty)
        XCTAssertEqual(anthropic.analyzeCalls.count, 1)
        XCTAssertEqual(appState.aiEngineStatus, .active(.anthropic))
    }

    func testNoEngineSetsUnavailableStatusAndReturnsNil() async {
        enableAI()
        let apple = FakeAITriageEngine(kind: .apple)
        apple.availabilityResult = .unavailable(reason: "This Mac doesn't support Apple Intelligence")
        let service = makeService(apple: apple, anthropic: FakeAITriageEngine(kind: .anthropic))

        let result = await service.analyze(text: "buy milk", capturedAt: now)

        XCTAssertNil(result)
        guard case .unavailable(let reason) = appState.aiEngineStatus else {
            return XCTFail("expected unavailable status")
        }
        XCTAssertTrue(reason.contains("no Anthropic API key"))
    }

    // MARK: - Timeout

    func testHangingEngineTimesOutAndReturnsNil() async {
        enableAI()
        let apple = FakeAITriageEngine(kind: .apple, behavior: .hang)
        let service = makeService(apple: apple, timeout: 0.05)

        let started = Date()
        let result = await service.analyze(text: "buy milk", capturedAt: now)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 2, "the race must not wait for the hanging engine")
        XCTAssertNotNil(appState.aiLastError)
    }

    // MARK: - Failure modes → deterministic fallback

    func testRefusalReturnsNilWithoutTransportStrike() async {
        enableAI()
        let apple = FakeAITriageEngine(kind: .apple, behavior: .error(.refusal))
        let service = makeService(apple: apple)

        for _ in 0..<3 {
            let result = await service.analyze(text: "buy milk", capturedAt: now)
            XCTAssertNil(result)
        }
        // No cooldown for refusals: every capture still tries.
        XCTAssertEqual(apple.analyzeCalls.count, 3)
    }

    func testGarbageOutputReturnsNil() async {
        enableAI()
        let apple = FakeAITriageEngine(kind: .apple, behavior: .error(.invalidOutput))
        let service = makeService(apple: apple)

        let result = await service.analyze(text: "buy milk", capturedAt: now)
        XCTAssertNil(result)
        XCTAssertNotNil(appState.aiLastError)
    }

    func testTransportFailuresTriggerCooldownThenRecover() async {
        enableAI()
        let apple = FakeAITriageEngine(kind: .apple, behavior: .error(.network("offline")))
        let service = makeService(apple: apple)

        // Two strikes reach the threshold…
        _ = await service.analyze(text: "one", capturedAt: now)
        _ = await service.analyze(text: "two", capturedAt: now)
        XCTAssertEqual(apple.analyzeCalls.count, 2)

        // …so the third capture makes no engine contact (cooldown).
        _ = await service.analyze(text: "three", capturedAt: now)
        XCTAssertEqual(apple.analyzeCalls.count, 2)

        // After the cooldown elapses (and the network is back), it recovers.
        clockBox.now = now.addingTimeInterval(AITriageService.failureCooldown + 1)
        apple.behavior = .draft(goodDraft)
        let result = await service.analyze(text: "four is a longer note", capturedAt: now)
        XCTAssertNotNil(result)
        XCTAssertEqual(apple.analyzeCalls.count, 3)
        XCTAssertNil(appState.aiLastError, "success clears the error")
    }

    // MARK: - 401 latch

    func test401LatchesKeyRejectedUntilKeyResaved() async {
        enableAI()
        credentials.key = "sk-bad"
        let apple = FakeAITriageEngine(kind: .apple)
        apple.availabilityResult = .unavailable(reason: "Apple Intelligence is turned off in System Settings")
        let anthropic = FakeAITriageEngine(kind: .anthropic, behavior: .error(.http(401)))
        let service = makeService(apple: apple, anthropic: anthropic)

        let rejected = await service.analyze(text: "buy milk", capturedAt: now)
        XCTAssertNil(rejected)
        XCTAssertTrue(service.keyRejected)
        XCTAssertTrue(appState.aiLastError?.contains("rejected") == true)

        // Latched: the next capture makes no network attempt.
        _ = await service.analyze(text: "buy eggs", capturedAt: now)
        XCTAssertEqual(anthropic.analyzeCalls.count, 1)

        // Re-saving a key clears the latch.
        credentials.key = "sk-good"
        anthropic.behavior = .draft(goodDraft)
        service.noteKeySaved()
        XCTAssertFalse(service.keyRejected)
        let result = await service.analyze(text: "buy bread and butter", capturedAt: now)
        XCTAssertNotNil(result)
        XCTAssertEqual(anthropic.analyzeCalls.count, 2)
    }

    // MARK: - Validation integration

    func testDraftFlowsThroughValidator() async {
        enableAI()
        let draft = AIEngineDraft(
            classification: "journal",
            title: "grateful for the rain today",
            formattedBody: nil,
            handoffs: [.init(kind: "reminder", title: "X", clause: "not in the note at all")]
        )
        let apple = FakeAITriageEngine(kind: .apple, behavior: .draft(draft))
        let service = makeService(apple: apple)

        let result = await service.analyze(text: "grateful for the rain today, felt calm", capturedAt: now)

        XCTAssertEqual(result?.classification, .journal)
        XCTAssertEqual(result?.title, "Grateful for the rain today")
        XCTAssertEqual(result?.handoffs.count, 0, "fabricated clause discarded")
        XCTAssertEqual(result?.handoffsInvalidated, true)
    }

    // MARK: - Status refresh

    func testRefreshStatusRespectsToggle() {
        let apple = FakeAITriageEngine(kind: .apple)
        let service = makeService(apple: apple)

        service.refreshStatus()
        XCTAssertEqual(appState.aiEngineStatus, .off)

        enableAI()
        service.refreshStatus()
        XCTAssertEqual(appState.aiEngineStatus, .active(.apple))
    }
}
