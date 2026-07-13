import XCTest
@testable import Rapture

/// The Settings toggle-enable flow: pre-prompt → request → persist/deny, with
/// the NSAlerts behind injected closures (the Replier prePromptHandler pattern).
@MainActor
final class HandoffEnableFlowTests: XCTestCase {

    private var fake: FakeEventKitClient!
    private var prePromptShown = 0
    private var deniedShown = 0

    override func setUp() {
        fake = FakeEventKitClient()
        prePromptShown = 0
        deniedShown = 0
    }

    private func enable(_ kind: HandoffKind, prePromptAnswer: Bool = true) async -> HandoffEnableFlow.Result {
        await HandoffEnableFlow.enable(
            kind: kind,
            client: fake,
            prePrompt: { self.prePromptShown += 1; return prePromptAnswer },
            showDenied: { self.deniedShown += 1 }
        )
    }

    func testAlreadyAuthorizedEnablesWithoutAnyPrompt() async {
        fake.statuses[.reminder] = .authorized
        let result = await enable(.reminder)
        XCTAssertEqual(result, HandoffEnableFlow.Result(enabled: true, error: nil))
        XCTAssertEqual(prePromptShown, 0)
        XCTAssertTrue(fake.accessRequests.isEmpty)
    }

    func testNotDeterminedShowsPrePromptThenRequestsAndEnablesOnGrant() async {
        fake.statuses[.event] = .notDetermined
        fake.requestResult = true
        let result = await enable(.event)
        XCTAssertEqual(result, HandoffEnableFlow.Result(enabled: true, error: nil))
        XCTAssertEqual(prePromptShown, 1, "the OS dialog must never appear unexplained")
        XCTAssertEqual(fake.accessRequests, [.event])
        XCTAssertEqual(deniedShown, 0)
    }

    func testCancellingPrePromptAbortsSilentlyWithoutRequesting() async {
        fake.statuses[.reminder] = .notDetermined
        let result = await enable(.reminder, prePromptAnswer: false)
        XCTAssertEqual(result, HandoffEnableFlow.Result(enabled: false, error: nil))
        XCTAssertTrue(fake.accessRequests.isEmpty, "cancel means the TCC dialog never fires")
        XCTAssertEqual(deniedShown, 0)
    }

    func testDenyingTheOSDialogLeavesToggleOffWithError() async {
        fake.statuses[.reminder] = .notDetermined
        fake.requestResult = false
        let result = await enable(.reminder)
        XCTAssertFalse(result.enabled)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(deniedShown, 1)
        XCTAssertEqual(fake.accessRequests, [.reminder])
    }

    func testPreviouslyDeniedShowsSystemSettingsNudgeWithoutRequesting() async {
        fake.statuses[.event] = .denied
        let result = await enable(.event)
        XCTAssertFalse(result.enabled)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(prePromptShown, 0, "no point pre-prompting — the OS won't ask again")
        XCTAssertTrue(fake.accessRequests.isEmpty)
        XCTAssertEqual(deniedShown, 1)
    }
}
