import XCTest
@testable import RaptureMac

final class AppleScriptSenderTests: XCTestCase {

    func testScriptMatchesSpecContract() {
        let expected = """
            on run argv
                tell application "Messages" to send (item 1 of argv) to chat id (item 2 of argv)
            end run
            """
        XCTAssertEqual(AppleScriptSender.script, expected)
    }

    func testPermissionDeniedClassifierMatchesKnownStderr() {
        // Canonical TCC denial — the -1743 error code is what macOS returns when
        // the Automation entitlement to Messages.app hasn't been granted yet.
        let dashed = AppleScriptSendError(exitCode: 1, stderr: "execution error: Not authorized to send Apple events to Messages. (-1743)")
        XCTAssertTrue(dashed.isPermissionDenied)

        let altPhrasing = AppleScriptSendError(exitCode: 1, stderr: "Not allowed to send Apple events to application Messages")
        XCTAssertTrue(altPhrasing.isPermissionDenied)

        let codeOnly = AppleScriptSendError(exitCode: 1, stderr: "some prefix (-1743) trailing")
        XCTAssertTrue(codeOnly.isPermissionDenied)
    }

    func testPermissionDeniedClassifierDoesNotMatchUnrelatedErrors() {
        let unrelated = AppleScriptSendError(exitCode: 1, stderr: "Can't get chat id \"X\". (-1728)")
        XCTAssertFalse(unrelated.isPermissionDenied)

        let empty = AppleScriptSendError(exitCode: 1, stderr: "")
        XCTAssertFalse(empty.isPermissionDenied)
    }

    func testUserFacingMessageUsesFirstStderrLine() {
        let err = AppleScriptSendError(exitCode: 1, stderr: "first failure line\nadditional detail")
        XCTAssertEqual(err.userFacingMessage, "first failure line")
    }

    func testUserFacingMessageFallsBackOnExitCodeWhenStderrEmpty() {
        let err = AppleScriptSendError(exitCode: 42, stderr: "")
        XCTAssertEqual(err.userFacingMessage, "AppleScript exited with code 42")
    }
}
