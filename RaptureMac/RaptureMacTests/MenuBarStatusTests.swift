import XCTest
@testable import Rapture

final class MenuBarStatusTests: XCTestCase {

    func testCapturingByDefault() {
        let line = MenuBarStatus.line(permission: .ok, automation: .ok, paused: false, lastError: nil)
        XCTAssertEqual(line.kind, .capturing)
        XCTAssertEqual(line.iconName, "text.bubble")
    }

    func testFullDiskAccessBeatsEverything() {
        let line = MenuBarStatus.line(
            permission: .fullDiskAccessRequired,
            automation: .required,
            paused: true,
            lastError: "writer exploded"
        )
        XCTAssertEqual(line.kind, .fullDiskAccessNeeded)
    }

    func testAutomationBeatsPausedAndError() {
        let line = MenuBarStatus.line(
            permission: .ok,
            automation: .required,
            paused: true,
            lastError: "writer exploded"
        )
        XCTAssertEqual(line.kind, .automationNeeded)
    }

    func testPausedBeatsError() {
        let line = MenuBarStatus.line(
            permission: .ok,
            automation: .ok,
            paused: true,
            lastError: "writer exploded"
        )
        XCTAssertEqual(line.kind, .paused)
        XCTAssertEqual(line.iconName, "pause.fill")
    }

    func testErrorShownWhenNothingElseWrong() {
        let line = MenuBarStatus.line(
            permission: .ok,
            automation: .ok,
            paused: false,
            lastError: "writer exploded"
        )
        XCTAssertEqual(line.kind, .error)
        XCTAssertTrue(line.primary.contains("writer exploded"))
    }

    func testEmptyErrorIsTreatedAsNoError() {
        let line = MenuBarStatus.line(permission: .ok, automation: .ok, paused: false, lastError: "")
        XCTAssertEqual(line.kind, .capturing)
    }

    func testUnknownPermissionShowsCapturingDuringStartup() {
        // .unknown is the pre-start state. Pipeline.start() resolves it to .ok or
        // .fullDiskAccessRequired within milliseconds. Showing "Capturing" briefly is
        // benign; explicitly flagging "FDA needed" before we've checked would be a lie.
        let line = MenuBarStatus.line(permission: .unknown, automation: .ok, paused: false, lastError: nil)
        XCTAssertEqual(line.kind, .capturing)
    }
}
