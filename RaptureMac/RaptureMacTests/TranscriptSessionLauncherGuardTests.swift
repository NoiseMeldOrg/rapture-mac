import XCTest
@testable import Rapture

/// The real launcher is front-guarded on XCTest: it throws before spawning any
/// `claude`, so the hosted suite starts no real session. Mirrors
/// `GitStateReaderGuardTests`.
@MainActor
final class TranscriptSessionLauncherGuardTests: XCTestCase {

    func testLauncherInertUnderTests() async {
        let launcher = ClaudeProcessSessionLauncher(loginPath: "/usr/bin:/bin")
        do {
            try await launcher.launch(prompt: "p", workingDirectory: URL(fileURLWithPath: "/tmp"))
            XCTFail("launcher must throw under XCTest — the suite spawns no real claude")
        } catch {
            XCTAssertEqual(error as? TranscriptSessionError, .unavailableUnderTests)
        }
        XCTAssertFalse(launcher.isRunning())
        XCTAssertNil(launcher.lastFailureDetail())
    }
}
