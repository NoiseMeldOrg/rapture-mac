import XCTest
@testable import Rapture

/// Pure table tests for repo-root discovery and the staleness decision — no real
/// git, no filesystem (the `.git` probe is injected). Mirrors `DestinationGuardTests`.
final class BackupHealthEvaluatorTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let threshold = BackupHealthEvaluator.defaultThreshold // 24h

    private func state(
        hasUpstream: Bool = true,
        dirty: Int = 0,
        unpushed: Int = 0,
        oldestUnpushed: Date? = nil,
        oldestDirtyMtime: Date? = nil,
        lastCommit: Date? = nil
    ) -> GitRepoState {
        GitRepoState(
            hasUpstream: hasUpstream,
            dirtyFileCount: dirty,
            unpushedCount: unpushed,
            oldestUnpushedCommit: oldestUnpushed,
            oldestDirtyFileMtime: oldestDirtyMtime,
            lastCommit: lastCommit
        )
    }

    private func evaluate(_ s: GitRepoState) -> BackupHealth {
        BackupHealthEvaluator.evaluate(state: s, now: now, threshold: threshold)
    }

    // MARK: - Repo-root discovery

    func testDiscoversRepoRootAboveOutputFolder() {
        // The real vault: output folder nested inside the repo.
        let output = URL(fileURLWithPath: "/Users/raptest/vault/inbox")
        let repoRoot = URL(fileURLWithPath: "/Users/raptest/vault")
        let found = BackupHealthEvaluator.discoverRepoRoot(from: output) { $0.path == repoRoot.path }
        XCTAssertEqual(found?.path, repoRoot.path)
    }

    func testOutputFolderItselfIsRepoRoot() {
        let output = URL(fileURLWithPath: "/Users/raptest/vault")
        let found = BackupHealthEvaluator.discoverRepoRoot(from: output) { $0.path == output.path }
        XCTAssertEqual(found?.path, output.path)
    }

    func testNoGitEntryReturnsNil() {
        let output = URL(fileURLWithPath: "/Users/raptest/plain/notes")
        let found = BackupHealthEvaluator.discoverRepoRoot(from: output) { _ in false }
        XCTAssertNil(found)
    }

    // MARK: - Healthy

    func testCleanRepoIsBackedUp() {
        let last = now.addingTimeInterval(-3_600)
        XCTAssertEqual(evaluate(state(lastCommit: last)), .backedUp(lastCommit: last, pendingChanges: 0))
    }

    func testFreshUncommittedWorkIsWithinGrace() {
        // Dirty, but only an hour old → not at risk; reported as pending.
        let s = state(dirty: 2, oldestDirtyMtime: now.addingTimeInterval(-3_600), lastCommit: now.addingTimeInterval(-3_600))
        XCTAssertEqual(evaluate(s), .backedUp(lastCommit: now.addingTimeInterval(-3_600), pendingChanges: 2))
    }

    // MARK: - At risk

    func testOldUncommittedWorkIsAtRisk() {
        let since = now.addingTimeInterval(-2 * threshold) // 2 days
        let s = state(dirty: 27, oldestDirtyMtime: since, lastCommit: since)
        XCTAssertEqual(evaluate(s), .atRisk(since: since, uncommitted: 27, unpushed: 0))
    }

    func testOldUnpushedCommitsAreAtRisk() {
        let since = now.addingTimeInterval(-3 * threshold)
        let s = state(unpushed: 4, oldestUnpushed: since, lastCommit: now.addingTimeInterval(-100))
        XCTAssertEqual(evaluate(s), .atRisk(since: since, uncommitted: 0, unpushed: 4))
    }

    func testAnchorIsEarliestOfDirtyAndUnpushed() {
        // Dirty work is older than the oldest unpushed commit → since = dirty mtime,
        // and both counts are reported.
        let dirtySince = now.addingTimeInterval(-3 * threshold)
        let unpushedSince = now.addingTimeInterval(-2 * threshold)
        let s = state(dirty: 5, unpushed: 2, oldestUnpushed: unpushedSince, oldestDirtyMtime: dirtySince)
        XCTAssertEqual(evaluate(s), .atRisk(since: dirtySince, uncommitted: 5, unpushed: 2))
    }

    // MARK: - Grace boundary

    func testExactlyAtThresholdIsNotYetAtRisk() {
        let since = now.addingTimeInterval(-threshold) // age == threshold, not > threshold
        let s = state(dirty: 1, oldestDirtyMtime: since)
        XCTAssertEqual(evaluate(s), .backedUp(lastCommit: nil, pendingChanges: 1))
    }

    func testJustPastThresholdIsAtRisk() {
        let since = now.addingTimeInterval(-threshold - 1)
        let s = state(dirty: 1, oldestDirtyMtime: since)
        XCTAssertEqual(evaluate(s), .atRisk(since: since, uncommitted: 1, unpushed: 0))
    }

    // MARK: - No upstream (graceful degrade)

    func testNoUpstreamCleanStaysQuiet() {
        // No upstream: "unpushed" is undefined, so a stale unpushedCount is ignored
        // and a clean tree reads as backed up — never a false alarm.
        let s = state(hasUpstream: false, dirty: 0, unpushed: 9, oldestUnpushed: now.addingTimeInterval(-5 * threshold))
        XCTAssertEqual(evaluate(s), .backedUp(lastCommit: nil, pendingChanges: 0))
    }

    func testNoUpstreamOldDirtyWorkIsAtRisk() {
        let since = now.addingTimeInterval(-2 * threshold)
        let s = state(hasUpstream: false, dirty: 3, unpushed: 9, oldestUnpushed: since, oldestDirtyMtime: since)
        // unpushed reported as 0 because there is no upstream to measure against.
        XCTAssertEqual(evaluate(s), .atRisk(since: since, uncommitted: 3, unpushed: 0))
    }
}
