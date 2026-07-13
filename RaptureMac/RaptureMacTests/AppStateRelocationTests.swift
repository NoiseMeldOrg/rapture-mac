import XCTest
@testable import Rapture

/// Closes the audit gap: the migrator is proven to leave the *source* intact on failure,
/// but nothing asserted that `AppState` also keeps the *active folder* (and sidecar)
/// unchanged when a relocate fails. This drives the real `setOutputFolder` contract.
///
/// `AppState`/`SettingsStore` persist to the app-support container (the DEBUG-isolated
/// one under test), so setUp/tearDown snapshot and restore those files to avoid
/// disturbing local dev state.
@MainActor
final class AppStateRelocationTests: XCTestCase {

    private let fm = FileManager.default
    private var temp: URL!
    private var snapshots: [URL: Data?] = [:]

    private func containerFile(_ name: String) throws -> URL {
        try AppSupportDirectory.url().appendingPathComponent(name)
    }

    override func setUpWithError() throws {
        temp = fm.temporaryDirectory.appendingPathComponent("appstate-reloc-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)

        // Snapshot the container files we may mutate so we can restore them afterward.
        for name in ["settings.json", "state.json", "output-folder.path"] {
            let url = try containerFile(name)
            snapshots[url] = fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : Optional<Data>.none
        }
    }

    override func tearDownWithError() throws {
        for (url, data) in snapshots {
            if let data {
                try data.write(to: url)
            } else if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
        }
        if let temp, fm.fileExists(atPath: temp.path) {
            try fm.removeItem(at: temp)
        }
    }

    func testFailedRelocateLeavesActiveFolderAndSidecarUnchanged() async throws {
        // Active folder = a populated source.
        let old = temp.appendingPathComponent("old", isDirectory: true)
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try "rules".write(to: old.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        try "note".write(to: old.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        // Destination exists but is read-only, so the move fails before anything is touched.
        let new = temp.appendingPathComponent("new", isDirectory: true)
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: new.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: new.path) }

        let appState = AppState()
        appState.settings.update { $0.outputFolder = old }

        let sidecar = try containerFile("output-folder.path")
        let sidecarBefore = fm.fileExists(atPath: sidecar.path) ? try Data(contentsOf: sidecar) : nil

        await appState.setOutputFolder(new)

        // Active folder unchanged.
        XCTAssertEqual(appState.settings.settings.outputFolder?.path, old.path,
                       "a failed relocate must not switch the active folder")
        // Status reflects the failure.
        guard case .failed = appState.relocationStatus else {
            return XCTFail("expected relocationStatus == .failed, got \(appState.relocationStatus)")
        }
        // Source tree intact.
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("CLAUDE.md"), encoding: .utf8), "rules")
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("a.txt"), encoding: .utf8), "note")
        // Sidecar (downstream-consumer contract) not rewritten to the failed destination.
        let sidecarAfter = fm.fileExists(atPath: sidecar.path) ? try Data(contentsOf: sidecar) : nil
        XCTAssertEqual(sidecarAfter, sidecarBefore, "sidecar must not point at a folder we failed to switch to")
    }

    func testRelocateToAbsentVolumeFailsWithoutShadowFolder() async throws {
        let old = temp.appendingPathComponent("old", isDirectory: true)
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try "note".write(to: old.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let phantom = URL(fileURLWithPath: "/Volumes/RaptureReloc-\(UUID().uuidString)/Notes")

        let appState = AppState()
        appState.settings.update { $0.outputFolder = old }

        await appState.setOutputFolder(phantom)

        XCTAssertEqual(appState.settings.settings.outputFolder?.path, old.path,
                       "relocating to an unplugged volume must not switch the folder")
        guard case .failed = appState.relocationStatus else {
            return XCTFail("expected relocationStatus == .failed, got \(appState.relocationStatus)")
        }
        XCTAssertFalse(fm.fileExists(atPath: phantom.deletingLastPathComponent().path),
                       "no shadow folder may appear under /Volumes")
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("a.txt"), encoding: .utf8), "note")
    }

    func testRelocateAwayFromAbsentVolumeSwitchesWithStrandedNotice() async throws {
        let phantomOld = URL(fileURLWithPath: "/Volumes/RaptureReloc-\(UUID().uuidString)/Notes")
        let new = temp.appendingPathComponent("new", isDirectory: true)

        let appState = AppState()
        appState.settings.update { $0.outputFolder = phantomOld }

        await appState.setOutputFolder(new)

        XCTAssertEqual(appState.settings.settings.outputFolder?.path, new.path,
                       "the user needs a working destination even while the old drive is unplugged")
        XCTAssertEqual(appState.relocationStatus, .idle)
        XCTAssertNotNil(appState.lastError, "stranded notes deserve an honest notice")
        XCTAssertTrue(appState.lastError?.contains("disconnected drive") == true, "got: \(appState.lastError ?? "nil")")
    }

    func testCollisionRenameRemapsTriageLedger() async throws {
        // Old and new both hold Notes/<name>.md; after relocation the incoming
        // note lands at -1 and its ledger entry must follow.
        let noteRel = "Notes/2026-07-10 Groceries.md"
        let old = temp.appendingPathComponent("old", isDirectory: true)
        try fm.createDirectory(at: old.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        try "incoming".write(to: old.appendingPathComponent(noteRel), atomically: true, encoding: .utf8)

        let new = temp.appendingPathComponent("new", isDirectory: true)
        try fm.createDirectory(at: new.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        try "existing".write(to: new.appendingPathComponent(noteRel), atomically: true, encoding: .utf8)

        let appState = AppState()
        appState.settings.update { $0.outputFolder = old }
        let ledger = TriageLedger(stateStore: appState.state)
        ledger.record(sourceFilename: "2026-07-10T14-00-00Z.txt", contentHash: "h", mdRelativePath: noteRel)

        await appState.setOutputFolder(new)

        XCTAssertEqual(appState.settings.settings.outputFolder?.path, new.path)
        XCTAssertEqual(
            ledger.entry(sourceFilename: "2026-07-10T14-00-00Z.txt")?.mdRelativePath,
            "Notes/2026-07-10 Groceries-1.md",
            "ledger must track the collision rename"
        )
    }

    func testNoOpWhenSettingSameFolder() async throws {
        let folder = temp.appendingPathComponent("notes", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try "x".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let appState = AppState()
        appState.settings.update { $0.outputFolder = folder }

        await appState.setOutputFolder(folder)

        XCTAssertEqual(appState.settings.settings.outputFolder?.path, folder.path)
        XCTAssertEqual(appState.relocationStatus, .idle, "no-op relocate should not enter a failed/in-progress state")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("a.txt"), encoding: .utf8), "x")
    }
}
