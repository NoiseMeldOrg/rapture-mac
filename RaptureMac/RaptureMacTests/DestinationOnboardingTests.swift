import XCTest
@testable import Rapture

/// Destination onboarding milestone 1: vault detection, containment, the
/// dry-run plan, relocation consent, and ledger pruning on "leave them behind".
/// Per-test temp dirs; the sidecar (which only writes to the app-support
/// container) is snapshotted and restored like `AppStateRelocationTests`.
@MainActor
final class DestinationOnboardingTests: XCTestCase {

    private let fm = FileManager.default
    private var temp: URL!
    private var sidecarSnapshot: Data??

    override func setUpWithError() throws {
        temp = fm.temporaryDirectory.appendingPathComponent("dest-onboard-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        let sidecar = try AppSupportDirectory.url().appendingPathComponent("output-folder.path")
        sidecarSnapshot = .some(fm.fileExists(atPath: sidecar.path) ? try Data(contentsOf: sidecar) : nil)
    }

    override func tearDownWithError() throws {
        let sidecar = try AppSupportDirectory.url().appendingPathComponent("output-folder.path")
        if case .some(let data) = sidecarSnapshot {
            if let data { try data.write(to: sidecar) } else { try? fm.removeItem(at: sidecar) }
        }
        if let temp, fm.fileExists(atPath: temp.path) {
            try fm.removeItem(at: temp)
        }
    }

    private func dir(_ path: String) throws -> URL {
        let url = temp.appendingPathComponent(path, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func file(_ path: String, _ text: String = "x") throws {
        let url = temp.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Obsidian config parsing

    func testParsesVaultPathsAndToleratesBadConfig() {
        let valid = #"{"vaults":{"a1":{"path":"/Volumes/Dock SSD/Obsidian/Second Brain","ts":1,"open":true},"b2":{"path":"/Users/me/Work"}}}"#
        XCTAssertEqual(Set(DestinationDetector.parseObsidianVaultPaths(Data(valid.utf8))),
                       ["/Volumes/Dock SSD/Obsidian/Second Brain", "/Users/me/Work"])
        XCTAssertEqual(DestinationDetector.parseObsidianVaultPaths(Data("not json".utf8)), [])
        XCTAssertEqual(DestinationDetector.parseObsidianVaultPaths(Data(#"{"vaults":{}}"#.utf8)), [])
        XCTAssertEqual(DestinationDetector.parseObsidianVaultPaths(Data(#"{"other":1}"#.utf8)), [])
        XCTAssertEqual(DestinationDetector.parseObsidianVaultPaths(Data(#"{"vaults":{"x":{"path":"relative"}}}"#.utf8)), [],
                       "only absolute paths")
    }

    func testDetectsReachableAndUnreachableVaultsAndSkipsDeletedOnes() throws {
        let present = try dir("Vaults/Alpha")
        let config = temp.appendingPathComponent("obsidian.json")
        let json = """
        {"vaults":{"1":{"path":"\(present.path)"},"2":{"path":"/Volumes/NotPlugged-\(UUID().uuidString)/Beta"},"3":{"path":"\(temp.path)/Vaults/Deleted"}}}
        """
        try json.write(to: config, atomically: true, encoding: .utf8)
        let env = DestinationDetector.Environment(
            home: temp.appendingPathComponent("home"),
            obsidianConfig: config,
            destinationGuard: DestinationGuard(),
            listDirectory: { _ in [] }
        )
        let vaults = DestinationDetector.vaults(in: env)
        XCTAssertEqual(vaults.map(\.name), ["Alpha", "Beta"], "deleted vault skipped, unplugged one kept")
        XCTAssertEqual(vaults.map(\.reachable), [true, false])
        XCTAssertEqual(vaults.first?.label, "Alpha — Obsidian vault")
    }

    func testMissingConfigMeansNoVaults() {
        let env = DestinationDetector.Environment(
            home: temp, obsidianConfig: temp.appendingPathComponent("absent.json"),
            destinationGuard: DestinationGuard(), listDirectory: { _ in [] })
        XCTAssertTrue(DestinationDetector.vaults(in: env).isEmpty)
    }

    func testFindsSyncRoots() throws {
        let home = try dir("home")
        try fm.createDirectory(at: home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"), withIntermediateDirectories: true)
        let storage = home.appendingPathComponent("Library/CloudStorage")
        try fm.createDirectory(at: storage.appendingPathComponent("Dropbox"), withIntermediateDirectories: true)
        try fm.createDirectory(at: storage.appendingPathComponent("GoogleDrive-me@example.com/My Drive"), withIntermediateDirectories: true)
        let env = DestinationDetector.Environment(
            home: home, obsidianConfig: temp.appendingPathComponent("none.json"),
            destinationGuard: DestinationGuard(),
            listDirectory: { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] })
        let roots = DestinationDetector.syncRoots(in: env)
        XCTAssertEqual(roots.map(\.name), ["iCloud Drive", "Dropbox", "Google Drive"])
        XCTAssertEqual(roots.last?.path.lastPathComponent, "My Drive")
    }

    // MARK: - Containment

    func testContainmentDecision() {
        XCTAssertEqual(Containment.decide(entries: []), .useDirectly)
        XCTAssertEqual(Containment.decide(entries: [".DS_Store"]), .useDirectly)
        XCTAssertEqual(Containment.decide(entries: ["Notes", "Links", "CLAUDE.md", ".DS_Store"]), .useDirectly, "already ours")
        XCTAssertEqual(Containment.decide(entries: ["2026-09-29T13-45-00Z.txt"]), .useDirectly, "raw-mode tree")
        XCTAssertEqual(Containment.decide(entries: ["Projects", "Daily"]), .offerContainer)
        XCTAssertEqual(Containment.decide(entries: [".obsidian"]), .offerContainer, "an empty-looking vault is still a vault")
    }

    func testContainerCheck() {
        XCTAssertEqual(Containment.checkContainer(entries: nil), .adopt)
        XCTAssertEqual(Containment.checkContainer(entries: []), .adopt)
        XCTAssertEqual(Containment.checkContainer(entries: ["Notes", "Meetings"]), .adopt)
        XCTAssertEqual(Containment.checkContainer(entries: ["Taxes 2025.pdf"]), .conflict)
        XCTAssertNil(Containment.sanitizedContainerName("   "))
        XCTAssertNil(Containment.sanitizedContainerName(".hidden"))
        XCTAssertEqual(Containment.sanitizedContainerName("Inbox/2"), "Inbox 2")
    }

    func testFlowOffersContainerForPopulatedVaultAndReasksOnConflict() throws {
        let vault = try dir("Vault")
        try dir("Vault/.obsidian")
        try file("Vault/Rapture Inbox/My own file.md")
        var asks: [(String, String?)] = []
        let target = DestinationChangeFlow.resolveTarget(chosen: vault) { _, suggested, problem in
            asks.append((suggested, problem))
            return asks.count == 1 ? .contain(name: "Rapture Inbox") : .contain(name: suggested)
        }
        XCTAssertEqual(asks.count, 2, "the taken name is refused once")
        XCTAssertEqual(asks[1].0, "Rapture Inbox 2")
        XCTAssertNotNil(asks[1].1)
        XCTAssertEqual(target?.lastPathComponent, "Rapture Inbox 2")
    }

    func testFlowUsesEmptyOrOwnFolderWithoutAsking() throws {
        let empty = try dir("Empty")
        let ours = try dir("Ours")
        try dir("Ours/Notes")
        for folder in [empty, ours, temp.appendingPathComponent("NotYetCreated")] {
            let target = DestinationChangeFlow.resolveTarget(chosen: folder) { _, _, _ in
                XCTFail("no containment question for \(folder.lastPathComponent)")
                return .cancel
            }
            XCTAssertEqual(target?.standardizedFileURL, folder.standardizedFileURL)
        }
    }

    func testFlowCancelAndUseFolderItself() throws {
        let vault = try dir("V")
        try file("V/Journal 2020.md")
        XCTAssertNil(DestinationChangeFlow.resolveTarget(chosen: vault) { _, _, _ in .cancel })
        XCTAssertEqual(DestinationChangeFlow.resolveTarget(chosen: vault) { _, _, _ in .useFolder }?.standardizedFileURL,
                       vault.standardizedFileURL)
    }

    // MARK: - Dry-run plan

    func testPlanCountsNotesFilesAndCollisions() throws {
        let old = try dir("old")
        let new = try dir("new")
        try file("old/Notes/2026-09-29 A.md")
        try file("old/Notes/2026-09-29 B.md")
        try file("old/Notes/2026-09-29 B/photo.jpg")
        try file("old/CLAUDE.md")
        try file("new/Notes/2026-09-29 B.md")
        let plan = OutputFolderMigrator().plan(from: old, to: new)
        XCTAssertEqual(plan.noteCount, 2, "CLAUDE.md is config, not a note")
        XCTAssertEqual(plan.fileCount, 4)
        XCTAssertEqual(plan.collisionCount, 1)
        XCTAssertTrue(OutputFolderMigrator().plan(from: new, to: new).isEmpty)
    }

    // MARK: - Consent

    private func appStateWithNotes() throws -> (AppState, URL, URL) {
        let old = try dir("From")
        try file("From/Notes/2026-09-29 A.md", "a")
        let new = try dir("To")
        let appState = AppState(supportDirectory: temp.appendingPathComponent("support"))
        appState.settings.update { $0.outputFolder = old }
        appState.state.update {
            $0.triagedRecords = [TriagedEntry(sourceFilename: "x.txt", contentHash: "h", mdRelativePath: "Notes/2026-09-29 A.md", triagedAt: Date())]
            $0.meetingRecords = [MeetingEntry(meetingId: "M", noteRelativePath: "Meetings/m.md", part: .transcript, relayFilenames: [], appliedSummaryHashes: [], updatedAt: Date())]
            $0.relayFiledRecords = [RelayFiledEntry(relayFilename: "r.txt", filedAt: Date())]
        }
        return (appState, old, new)
    }

    func testCancelLeavesEverythingUntouched() async throws {
        let (appState, old, new) = try appStateWithNotes()
        var shown: OutputFolderMigrator.Plan?
        await appState.setOutputFolder(new) { plan, _, _ in shown = plan; return .cancel }
        XCTAssertEqual(shown?.noteCount, 1)
        XCTAssertEqual(appState.settings.settings.outputFolder?.standardizedFileURL, old.standardizedFileURL)
        XCTAssertEqual(appState.relocationStatus, .idle)
        XCTAssertTrue(fm.fileExists(atPath: old.appendingPathComponent("Notes/2026-09-29 A.md").path))
        XCTAssertEqual(appState.state.state.triagedRecords.count, 1)
    }

    func testLeaveBehindSwitchesAndPrunesOnlyPathRecords() async throws {
        let (appState, old, new) = try appStateWithNotes()
        await appState.setOutputFolder(new) { _, _, _ in .leaveBehind }
        XCTAssertEqual(appState.settings.settings.outputFolder?.standardizedFileURL, new.standardizedFileURL)
        XCTAssertTrue(fm.fileExists(atPath: old.appendingPathComponent("Notes/2026-09-29 A.md").path), "the notes stay")
        XCTAssertFalse(fm.fileExists(atPath: new.appendingPathComponent("Notes").path))
        XCTAssertTrue(appState.state.state.triagedRecords.isEmpty, "paths into the old folder are forgotten")
        XCTAssertTrue(appState.state.state.meetingRecords.isEmpty)
        XCTAssertEqual(appState.state.state.relayFiledRecords.count, 1, "name-keyed records stay, so nothing re-files")
        let sidecar = try String(contentsOf: AppSupportDirectory.url().appendingPathComponent("output-folder.path"), encoding: .utf8)
        XCTAssertTrue(sidecar.contains(new.lastPathComponent))
    }

    func testMoveStillMovesAndKeepsLedgers() async throws {
        let (appState, _, new) = try appStateWithNotes()
        await appState.setOutputFolder(new) { _, _, _ in .move }
        XCTAssertTrue(fm.fileExists(atPath: new.appendingPathComponent("Notes/2026-09-29 A.md").path))
        XCTAssertEqual(appState.state.state.triagedRecords.first?.mdRelativePath, "Notes/2026-09-29 A.md",
                       "relative paths still resolve in the new folder")
    }

    func testNoQuestionWhenThereIsNothingToMove() async throws {
        let empty = try dir("EmptyOld")
        let new = try dir("New2")
        let appState = AppState(supportDirectory: temp.appendingPathComponent("support2"))
        appState.settings.update { $0.outputFolder = empty }
        await appState.setOutputFolder(new) { _, _, _ in
            XCTFail("nothing to move, nothing to ask")
            return .cancel
        }
        XCTAssertEqual(appState.settings.settings.outputFolder?.standardizedFileURL, new.standardizedFileURL)
    }

    func testContainedTargetBecomesTheSidecarPath() async throws {
        let vault = try dir("Vault2")
        try file("Vault2/Projects/plan.md")
        let appState = AppState(supportDirectory: temp.appendingPathComponent("support3"))
        appState.settings.update { $0.outputFolder = try? self.dir("Start") }
        await DestinationChangeFlow.change(
            to: vault, appState: appState,
            prompt: { _, suggested, _ in .contain(name: suggested) },
            consent: { _, _, _ in .move })
        let expected = vault.appendingPathComponent("Rapture Inbox").standardizedFileURL
        XCTAssertEqual(appState.settings.settings.outputFolder?.standardizedFileURL, expected)
        let sidecar = try String(contentsOf: AppSupportDirectory.url().appendingPathComponent("output-folder.path"), encoding: .utf8)
        XCTAssertTrue(sidecar.contains("Vault2/Rapture Inbox"), "consumers see the container, got \(sidecar)")
        XCTAssertTrue(fm.fileExists(atPath: vault.appendingPathComponent("Projects/plan.md").path), "the vault's own files are untouched")
    }

    // MARK: - M2: first-run choice

    func testOnlyAFreshInstallOwesTheQuestionAndOnlyAfterFullDiskAccess() {
        let fresh = AppState(supportDirectory: temp.appendingPathComponent("fresh"))
        XCTAssertTrue(fresh.state.state.destinationChoicePending)
        XCTAssertFalse(DestinationChoiceFlow.shouldPresent(appState: fresh), "Full Disk Access comes first")
        fresh.permissionState = .ok
        XCTAssertTrue(DestinationChoiceFlow.shouldPresent(appState: fresh))

        // The same install after the Full Disk Access relaunch still owes it.
        let relaunched = AppState(supportDirectory: temp.appendingPathComponent("fresh"))
        relaunched.permissionState = .ok
        XCTAssertTrue(DestinationChoiceFlow.shouldPresent(appState: relaunched))

        let existing = try? JSONDecoder().decode(PersistedState.self, from: Data(#"{"chatDbWatermark": 9}"#.utf8))
        XCTAssertEqual(existing?.destinationChoicePending, false, "updaters are never shown the first-run window")
        XCTAssertEqual(existing?.defaultDestinationNudgeDismissed, false)
    }

    func testKeepTheDefaultSettlesTheQuestionForGood() {
        let appState = AppState(supportDirectory: temp.appendingPathComponent("keep"))
        appState.permissionState = .ok
        DestinationChoiceFlow.keepDefault(appState: appState)
        XCTAssertFalse(DestinationChoiceFlow.shouldPresent(appState: appState))
        XCTAssertTrue(appState.state.state.defaultDestinationNudgeDismissed, "no nudge ever")
        let reloaded = AppState(supportDirectory: temp.appendingPathComponent("keep"))
        XCTAssertTrue(reloaded.state.state.defaultDestinationNudgeDismissed)
    }

    func testClosingWithoutAnswerStopsAskingButLeavesTheNudge() {
        let appState = AppState(supportDirectory: temp.appendingPathComponent("close"))
        DestinationChoiceFlow.dismiss(appState: appState)
        XCTAssertFalse(appState.state.state.destinationChoicePending)
        XCTAssertFalse(appState.state.state.defaultDestinationNudgeDismissed)
    }

    func testANoteFiledBeforeTheAnswerMovesWithTheChoice() async throws {
        // The default folder exists underneath from the start; a relay note
        // files into it while the question is still open.
        let defaultFolder = try dir("Rapture Notes")
        let relay = try dir("relay")
        let appState = AppState(supportDirectory: temp.appendingPathComponent("early"))
        appState.settings.update {
            $0.outputFolder = defaultFolder
            $0.relayEnabled = true
            $0.triageMode = .full
        }
        let processor = RelayProcessor(
            appState: appState, filer: RelayFiler(),
            ledger: RelayFiledLedger(stateStore: appState.state),
            triageLedger: TriageLedger(stateStore: appState.state))
        let base = "2026-09-29T20-00-00Z Early idea"
        let txt = relay.appendingPathComponent(base + ".txt")
        try "# Early idea\n\nbuy a label maker".write(to: txt, atomically: true, encoding: .utf8)
        await processor.process(batch: RelayScanBatch(
            candidates: [RelayCandidate(txtURL: txt, audioURL: nil, relayFilename: base + ".txt", baseName: base)],
            orphanAudio: []))
        XCTAssertTrue(appState.state.state.destinationChoicePending, "capture never waits on the answer")
        let filed = try XCTUnwrap(appState.state.state.triagedRecords.first?.mdRelativePath)
        XCTAssertTrue(fm.fileExists(atPath: defaultFolder.appendingPathComponent(filed).path))

        // Now the user picks a vault; the early note moves into its container.
        let vault = try dir("Vault3")
        try dir("Vault3/.obsidian")
        let moved = await DestinationChoiceFlow.choose(
            vault, appState: appState,
            prompt: { _, suggested, _ in .contain(name: suggested) },
            consent: { _, _, _ in .move })
        XCTAssertTrue(moved)
        XCTAssertFalse(appState.state.state.destinationChoicePending)
        XCTAssertTrue(fm.fileExists(atPath: vault.appendingPathComponent("Rapture Inbox").appendingPathComponent(filed).path),
                      "the early note is in the chosen vault, and its ledger path still resolves")
    }

    func testCancellingInsideTheChoiceLeavesTheQuestionOpen() async throws {
        let appState = AppState(supportDirectory: temp.appendingPathComponent("cancel2"))
        appState.settings.update { $0.outputFolder = try? self.dir("Default2") }
        let vault = try dir("Vault4")
        try dir("Vault4/.obsidian")
        let moved = await DestinationChoiceFlow.choose(vault, appState: appState, prompt: { _, _, _ in .cancel }, consent: { _, _, _ in .move })
        XCTAssertFalse(moved)
        XCTAssertTrue(appState.state.state.destinationChoicePending)
    }
}
