import XCTest
@testable import Rapture

/// Drives `BackupHealthMonitor.tick()` with a fake reader + injected clock and a
/// synthetic repo tree (the `.git` probe and volume guard are injected), asserting
/// the published `AppState.backupHealth` for each case. No real git, no network.
@MainActor
final class BackupHealthMonitorTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("backup-mon-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) { try fm.removeItem(at: root) }
    }

    private func makeAppState(outputFolder: URL) -> AppState {
        let appState = AppState(supportDirectory: root.appendingPathComponent("support", isDirectory: true))
        appState.settings.update { $0.outputFolder = outputFolder }
        return appState
    }

    private func makeMonitor(
        appState: AppState,
        reader: any GitStateReading,
        repoRoots: Set<String> = [],
        available: Bool = true
    ) -> BackupHealthMonitor {
        BackupHealthMonitor(
            appState: appState,
            reader: reader,
            destinationGuard: DestinationGuard(directoryExists: { _ in available }, isVolumeRoot: { _ in available }),
            hasGitEntry: { repoRoots.contains($0.path) },
            threshold: BackupHealthEvaluator.defaultThreshold,
            now: { [now] in now }
        )
    }

    private func cleanState(lastCommit: Date?) -> GitRepoState {
        GitRepoState(hasUpstream: true, dirtyFileCount: 0, unpushedCount: 0,
                     oldestUnpushedCommit: nil, oldestDirtyFileMtime: nil, lastCommit: lastCommit)
    }

    func testNotARepoWhenNoGitFound() async {
        let reader = FakeGitStateReader(behavior: .state(cleanState(lastCommit: now)))
        let appState = makeAppState(outputFolder: URL(fileURLWithPath: "/Users/raptest/plain/notes"))
        let monitor = makeMonitor(appState: appState, reader: reader, repoRoots: [])

        await monitor.tick()

        XCTAssertEqual(appState.backupHealth, .notARepo)
        XCTAssertTrue(reader.readRoots.isEmpty, "no repo → reader must not be asked to read")
    }

    func testBackedUpWhenRepoCleanAboveOutputFolder() async {
        let last = now.addingTimeInterval(-3_600)
        let reader = FakeGitStateReader(behavior: .state(cleanState(lastCommit: last)))
        let appState = makeAppState(outputFolder: URL(fileURLWithPath: "/Users/raptest/vault/inbox"))
        let monitor = makeMonitor(appState: appState, reader: reader, repoRoots: ["/Users/raptest/vault"])

        await monitor.tick()

        XCTAssertEqual(appState.backupHealth, .backedUp(lastCommit: last, pendingChanges: 0))
        // Discovery walked UP past the output folder to the repo root.
        XCTAssertEqual(reader.readRoots.map(\.path), ["/Users/raptest/vault"])
    }

    func testCannotCheckWhenVolumeAbsent() async {
        let reader = FakeGitStateReader(behavior: .state(cleanState(lastCommit: now)))
        let appState = makeAppState(outputFolder: URL(fileURLWithPath: "/Volumes/Ext SSD/vault/inbox"))
        let monitor = makeMonitor(appState: appState, reader: reader, repoRoots: ["/Volumes/Ext SSD/vault"], available: false)

        await monitor.tick()

        XCTAssertEqual(appState.backupHealth, .cannotCheck)
        XCTAssertTrue(reader.readRoots.isEmpty, "volume absent → don't spawn git")
    }

    func testAtRiskWhenReaderReportsOldWork() async {
        let since = now.addingTimeInterval(-2 * BackupHealthEvaluator.defaultThreshold)
        let state = GitRepoState(hasUpstream: true, dirtyFileCount: 5, unpushedCount: 0,
                                 oldestUnpushedCommit: nil, oldestDirtyFileMtime: since, lastCommit: since)
        let reader = FakeGitStateReader(behavior: .state(state))
        let appState = makeAppState(outputFolder: URL(fileURLWithPath: "/Users/raptest/vault"))
        let monitor = makeMonitor(appState: appState, reader: reader, repoRoots: ["/Users/raptest/vault"])

        await monitor.tick()

        XCTAssertEqual(appState.backupHealth, .atRisk(since: since, uncommitted: 5, unpushed: 0))
    }

    func testCannotCheckWhenReaderThrows() async {
        let reader = FakeGitStateReader(behavior: .failure(.gitFailed(exitCode: 128, stderr: "boom")))
        let appState = makeAppState(outputFolder: URL(fileURLWithPath: "/Users/raptest/vault"))
        let monitor = makeMonitor(appState: appState, reader: reader, repoRoots: ["/Users/raptest/vault"])

        await monitor.tick()

        XCTAssertEqual(appState.backupHealth, .cannotCheck)
    }
}
