import XCTest
@testable import Rapture

final class StatusPillResolutionTests: XCTestCase {

    private func makeInstall(statusKey: StatusKey?) -> InstallProfile {
        InstallProfile(
            id: "test",
            name: "Test",
            description: "",
            install: nil,
            uninstall: nil,
            start: nil,
            stop: nil,
            restart: nil,
            logs: [],
            statusKey: statusKey,
            configFile: nil,
            config: [],
            requires: .empty
        )
    }

    // MARK: - Hook

    func testHookNotInstalledWhenScriptMissing() {
        var report = StatusReport.empty
        report.hook.scriptInstalled = false
        report.hook.registered = false
        let pill = pillForInstall(makeInstall(statusKey: .hook), status: report)
        XCTAssertEqual(pill, .notInstalled)
    }

    func testHookPartialWhenScriptInstalledButNotRegistered() {
        var report = StatusReport.empty
        report.hook.scriptInstalled = true
        report.hook.registered = false
        let pill = pillForInstall(makeInstall(statusKey: .hook), status: report)
        XCTAssertEqual(pill, .partiallyInstalled)
    }

    func testHookInstalledWhenBothPresent() {
        var report = StatusReport.empty
        report.hook.scriptInstalled = true
        report.hook.registered = true
        let pill = pillForInstall(makeInstall(statusKey: .hook), status: report)
        XCTAssertEqual(pill, .installed)
    }

    // MARK: - Defaults

    func testNilStatusReportReturnsNotInstalled() {
        let pill = pillForInstall(makeInstall(statusKey: .hook), status: nil)
        XCTAssertEqual(pill, .notInstalled)
    }

    func testNilStatusKeyReturnsNotInstalled() {
        let pill = pillForInstall(makeInstall(statusKey: nil), status: StatusReport.empty)
        XCTAssertEqual(pill, .notInstalled)
    }

    func testUnknownStatusKeyReturnsUnknown() {
        let pill = pillForInstall(makeInstall(statusKey: .unknown("openclaw")), status: StatusReport.empty)
        XCTAssertEqual(pill, .unknown)
    }
}
