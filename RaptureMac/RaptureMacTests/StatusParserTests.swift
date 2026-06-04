import XCTest
@testable import Rapture

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
          ✗ CLAUDE.md routing rules missing — install script will fetch on next run
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
        let output = """
        Rapture for Mac — Claude Code integration status
        =================================================

        SessionStart hook (opportunistic triage):
          \u{1B}[32m✓\u{1B}[0m Check script: /Users/me/.claude/scripts/rapture-notes-check.sh
          \u{1B}[32m✓\u{1B}[0m Registered in /Users/me/.claude/settings.json

        Notes folder:
          Path:        /Users/me/Documents/Rapture Notes
          Source:      from Rapture's sidecar
          Pending:     2 .txt file(s) in root
          \u{1B}[32m✓\u{1B}[0m CLAUDE.md routing rules present
        """
        let r = StatusParser.parse(output)
        XCTAssertTrue(r.hook.scriptInstalled)
        XCTAssertTrue(r.hook.registered)
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
