import XCTest
@testable import RaptureMac

final class StatusParserTests: XCTestCase {

    // MARK: - Empty / garbage

    func testEmptyInputReturnsAllDefaults() {
        let r = StatusParser.parse("")
        XCTAssertEqual(r, StatusReport.empty)
    }

    func testGarbageInputReturnsAllDefaults() {
        let r = StatusParser.parse("this is\nnot status output\nat all")
        XCTAssertEqual(r, StatusReport.empty)
    }

    // MARK: - Hook section

    func testHookInstalledAndRegistered() {
        let output = """
        SessionStart hook (opportunistic triage):
          ✓ Check script: /Users/me/.claude/scripts/rapture-notes-check.sh
          ✓ Registered in /Users/me/.claude/settings.json
        """
        let r = StatusParser.parse(output)
        XCTAssertTrue(r.hook.scriptInstalled)
        XCTAssertTrue(r.hook.registered)
    }

    func testHookNotInstalled() {
        let output = """
        SessionStart hook (opportunistic triage):
          ✗ Check script not installed
          ✗ Not registered (settings.json missing or invalid)
        """
        let r = StatusParser.parse(output)
        XCTAssertFalse(r.hook.scriptInstalled)
        XCTAssertFalse(r.hook.registered)
    }

    func testHookScriptInstalledButNotRegistered() {
        let output = """
        SessionStart hook (opportunistic triage):
          ✓ Check script: /path/to/check.sh
          ✗ Not registered in /Users/me/.claude/settings.json
        """
        let r = StatusParser.parse(output)
        XCTAssertTrue(r.hook.scriptInstalled)
        XCTAssertFalse(r.hook.registered)
    }

    // MARK: - Watcher section: install state

    func testWatcherWorkerAndPlistInstalled() {
        let output = """
        Event-driven watcher (autonomous):
          ✓ Worker script: /Users/me/.claude/scripts/rapture-notes-watch.sh
          ✓ Plist: /Users/me/Library/LaunchAgents/com.user.rapture-notes-watch.plist
          ✗ Not loaded in launchd
          ✗ fswatch not running
        """
        let r = StatusParser.parse(output)
        XCTAssertTrue(r.watcher.workerInstalled)
        XCTAssertTrue(r.watcher.plistInstalled)
        XCTAssertEqual(r.watcher.launchdState, .notLoaded)
        XCTAssertNil(r.watcher.fswatchPid)
    }

    func testWatcherNotInstalled() {
        let output = """
        Event-driven watcher (autonomous):
          ✗ Worker script not installed
          ✗ Plist not installed
          ✗ Not loaded in launchd
          ✗ fswatch not running
        """
        let r = StatusParser.parse(output)
        XCTAssertFalse(r.watcher.workerInstalled)
        XCTAssertFalse(r.watcher.plistInstalled)
        XCTAssertEqual(r.watcher.launchdState, .notLoaded)
    }

    // MARK: - Watcher section: launchd states

    func testWatcherLoadedAndRunningWithPID() {
        let output = """
        Event-driven watcher (autonomous):
          ✓ Worker script: /path
          ✓ Plist: /plist
          ✓ Loaded in launchd (PID 42123; last exit code: 0)
          ✓ fswatch running: PID 42124
        """
        let r = StatusParser.parse(output)
        XCTAssertEqual(r.watcher.launchdState, .loaded(pid: 42123, lastExit: 0, idle: false))
        XCTAssertEqual(r.watcher.fswatchPid, 42124)
    }

    func testWatcherLoadedAndIdle() {
        let output = """
        Event-driven watcher (autonomous):
          ✓ Loaded in launchd (idle; last exit code: 0)
        """
        let r = StatusParser.parse(output)
        XCTAssertEqual(r.watcher.launchdState, .loaded(pid: nil, lastExit: 0, idle: true))
    }

    func testWatcherLoadedWithNegativeExitCode() {
        let output = """
        Event-driven watcher (autonomous):
          ✓ Loaded in launchd (idle; last exit code: -9)
        """
        let r = StatusParser.parse(output)
        XCTAssertEqual(r.watcher.launchdState, .loaded(pid: nil, lastExit: -9, idle: true))
    }

    // MARK: - Watcher section: fswatch dead but launchd up (degenerate case)

    func testFswatchDeadButLaunchdLoaded() {
        let output = """
        Event-driven watcher (autonomous):
          ✓ Worker script: /path
          ✓ Plist: /plist
          ✓ Loaded in launchd (PID 100; last exit code: 0)
          ✗ fswatch not running
        """
        let r = StatusParser.parse(output)
        if case .loaded(let pid, _, _) = r.watcher.launchdState {
            XCTAssertEqual(pid, 100)
        } else {
            XCTFail("expected .loaded")
        }
        XCTAssertNil(r.watcher.fswatchPid)
    }

    // MARK: - Watcher section: last log / err lines

    func testWatcherLastLogLineCaptured() {
        let output = """
        Event-driven watcher (autonomous):
          ✓ Loaded in launchd (PID 1; last exit code: 0)
          ✓ fswatch running: PID 2
          Last log line: [2026-05-29T18:42:15+00:00] processing 2 pending note(s) one at a time
        """
        let r = StatusParser.parse(output)
        XCTAssertEqual(r.watcher.lastLogLine, "[2026-05-29T18:42:15+00:00] processing 2 pending note(s) one at a time")
    }

    func testWatcherLastErrLineCaptured() {
        let output = """
        Event-driven watcher (autonomous):
          Last err line: some error happened
        """
        let r = StatusParser.parse(output)
        XCTAssertEqual(r.watcher.lastErrLine, "some error happened")
    }

    // MARK: - Notes folder section

    func testNotesFolderFullyReported() {
        let output = """
        Notes folder:
          Path:        /Users/me/Documents/Rapture Notes
          Source:      from Rapture's sidecar
          Pending:     3 .txt file(s) in root
          ✓ CLAUDE.md routing rules present
        """
        let r = StatusParser.parse(output)
        XCTAssertEqual(r.notesFolder.path, "/Users/me/Documents/Rapture Notes")
        XCTAssertEqual(r.notesFolder.source, "from Rapture's sidecar")
        XCTAssertEqual(r.notesFolder.pending, 3)
        XCTAssertTrue(r.notesFolder.claudeMdPresent)
    }

    func testNotesFolderPendingZero() {
        let output = """
        Notes folder:
          Path:        /tmp/x
          Source:      default (sidecar not present)
          Pending:     0 .txt file(s) in root
          ✓ CLAUDE.md routing rules present
        """
        let r = StatusParser.parse(output)
        XCTAssertEqual(r.notesFolder.pending, 0)
    }

    func testNotesFolderClaudeMdMissing() {
        let output = """
        Notes folder:
          Path:        /tmp/x
          Source:      default
          Pending:     0 .txt file(s) in root
          ✗ CLAUDE.md routing rules missing — install scripts will fetch on next run
        """
        let r = StatusParser.parse(output)
        XCTAssertFalse(r.notesFolder.claudeMdPresent)
    }

    func testNotesFolderDoesNotExist() {
        let output = """
        Notes folder:
          Path:        /tmp/no-such-dir
          Source:      default
          ✗ Folder does not exist — launch Rapture once to auto-create
        """
        let r = StatusParser.parse(output)
        XCTAssertEqual(r.notesFolder.path, "/tmp/no-such-dir")
        XCTAssertNil(r.notesFolder.pending)
        XCTAssertFalse(r.notesFolder.claudeMdPresent)
    }

    // MARK: - ANSI stripping

    func testANSIEscapesAreStripped() {
        let output = "  \u{1B}[32m✓\u{1B}[0m Check script: /path"
        XCTAssertEqual(StatusParser.stripANSI(output), "  ✓ Check script: /path")
    }

    func testFullANSIInputParses() {
        // Realistic capture with ANSI codes around every glyph.
        let output = """
        Rapture for Mac — Claude Code integration status
        =================================================

        SessionStart hook (opportunistic triage):
          \u{1B}[32m✓\u{1B}[0m Check script: /Users/me/.claude/scripts/rapture-notes-check.sh
          \u{1B}[32m✓\u{1B}[0m Registered in /Users/me/.claude/settings.json

        Event-driven watcher (autonomous):
          \u{1B}[32m✓\u{1B}[0m Worker script: /Users/me/.claude/scripts/rapture-notes-watch.sh
          \u{1B}[32m✓\u{1B}[0m Plist: /Users/me/Library/LaunchAgents/com.user.rapture-notes-watch.plist
          \u{1B}[32m✓\u{1B}[0m Loaded in launchd (PID 12345; last exit code: 0)
          \u{1B}[32m✓\u{1B}[0m fswatch running: PID 12346
          Last log line: [2026-05-31T20:00:00+00:00] processed note.txt

        Notes folder:
          Path:        /Users/me/Documents/Rapture Notes
          Source:      from Rapture's sidecar
          Pending:     2 .txt file(s) in root
          \u{1B}[32m✓\u{1B}[0m CLAUDE.md routing rules present
        """
        let r = StatusParser.parse(output)
        XCTAssertTrue(r.hook.scriptInstalled)
        XCTAssertTrue(r.hook.registered)
        XCTAssertTrue(r.watcher.workerInstalled)
        XCTAssertTrue(r.watcher.plistInstalled)
        XCTAssertEqual(r.watcher.launchdState, .loaded(pid: 12345, lastExit: 0, idle: false))
        XCTAssertEqual(r.watcher.fswatchPid, 12346)
        XCTAssertEqual(r.watcher.lastLogLine, "[2026-05-31T20:00:00+00:00] processed note.txt")
        XCTAssertEqual(r.notesFolder.path, "/Users/me/Documents/Rapture Notes")
        XCTAssertEqual(r.notesFolder.source, "from Rapture's sidecar")
        XCTAssertEqual(r.notesFolder.pending, 2)
        XCTAssertTrue(r.notesFolder.claudeMdPresent)
    }

    // MARK: - Section isolation

    func testCommandsSectionIsIgnored() {
        let output = """
        Notes folder:
          Path:        /x
        Commands:
          Install hook:        curl ... | bash
          Stop watcher:        bash Scripts/stop-watch.sh
        """
        let r = StatusParser.parse(output)
        XCTAssertEqual(r.notesFolder.path, "/x")
        XCTAssertNil(r.notesFolder.pending)
    }

    func testUnrelatedLinesBetweenSectionsAreIgnored() {
        let output = """
        Random preamble line that should be ignored.

        SessionStart hook (opportunistic triage):
          ✓ Check script: /a
        Garbage line in between that mentions nothing valuable.
          ✓ Registered in /b
        """
        let r = StatusParser.parse(output)
        XCTAssertTrue(r.hook.scriptInstalled)
        XCTAssertTrue(r.hook.registered)
    }

    // MARK: - stripMarker helper

    func testStripMarkerRemovesCheckMarker() {
        XCTAssertEqual(StatusParser.stripMarker("  ✓ Check script: /x"), "Check script: /x")
    }

    func testStripMarkerRemovesXMarker() {
        XCTAssertEqual(StatusParser.stripMarker("  ✗ Not installed"), "Not installed")
    }

    func testStripMarkerHandlesNoMarker() {
        XCTAssertEqual(StatusParser.stripMarker("  Path:        /x"), "Path:        /x")
    }
}
