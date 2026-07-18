import XCTest
@testable import Rapture

/// The real reader is front-guarded on XCTest: it throws before spawning any
/// `git`, so the hosted suite reads no real repo and opens no socket. Mirrors
/// `EnrichmentGuardTests`.
@MainActor
final class GitStateReaderGuardTests: XCTestCase {

    func testReaderInertUnderTests() async {
        let reader = SystemGitStateReader()
        do {
            _ = try await reader.readState(repoRoot: URL(fileURLWithPath: "/tmp"))
            XCTFail("reader must throw under XCTest — the suite spawns no real git")
        } catch {
            XCTAssertEqual(error as? GitReadError, .unavailableUnderTests)
        }
    }
}
