import XCTest
@testable import Rapture

/// The 1.0.126 trust surfaces: the activity history, per-source errors,
/// phone-aware allowlist matching, new reply shapes vs the echo filter, the
/// status line with replies off, the fresh-install notice, and late
/// attachment recovery.
@MainActor
final class ActivityAndErrorsTests: XCTestCase {

    private let fm = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("activity-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
    }

    // MARK: - ActivityLog

    func testActivityPersistsNewestFirstAndSurvivesReload() throws {
        let log = ActivityLog(directory: root)
        log.record(.filed, source: .iMessage, "First")
        log.record(.reminderCreated, source: .app, "Reminder created: call the bank")
        XCTAssertEqual(log.recent.map(\.summary), ["Reminder created: call the bank", "First"])

        let reloaded = ActivityLog(directory: root)
        XCTAssertEqual(reloaded.recent.map(\.summary), ["Reminder created: call the bank", "First"])
    }

    func testTornLineIsSkippedNotFatal() throws {
        let log = ActivityLog(directory: root)
        log.record(.filed, source: .iMessage, "Good")
        let url = root.appendingPathComponent(ActivityLog.fileName)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"broken\":\n".utf8))
        try handle.close()
        XCTAssertEqual(ActivityLog(directory: root).recent.map(\.summary), ["Good"])
    }

    func testLastNoteSkipsNotesThatNoLongerExist() throws {
        let log = ActivityLog(directory: root)
        let kept = root.appendingPathComponent("kept.md")
        try "x".write(to: kept, atomically: true, encoding: .utf8)
        log.record(.filed, source: .iMessage, "kept", path: kept)
        log.record(.filed, source: .iMessage, "deleted", path: root.appendingPathComponent("gone.md"))
        log.record(.reminderCreated, source: .app, "not a note")
        XCTAssertEqual(log.lastNote?.summary, "kept")
    }

    // MARK: - Errors

    func testErrorsArePerSourceAndPersistWithTimes() {
        let appState = AppState(supportDirectory: root)
        let early = Date(timeIntervalSince1970: 1_800_000_000)
        appState.recordError("Relay stuck", source: .relay, at: early)
        appState.recordError("Disk full", source: .capture, at: early + 60)
        XCTAssertEqual(appState.lastError, "Disk full", "the newest error is shown")

        appState.clearError(source: .capture)
        XCTAssertEqual(appState.lastError, "Relay stuck", "a capture success must not hide the relay error")

        let reloaded = AppState(supportDirectory: root)
        XCTAssertEqual(reloaded.lastError, "Relay stuck")
        XCTAssertEqual(reloaded.lastErrorAt, early, "the real time survives a relaunch")

        reloaded.dismissAllErrors()
        XCTAssertNil(reloaded.lastError)
    }

    func testLegacyLastErrorStringStillShows() throws {
        let legacy = #"{"chatDbWatermark": 3, "lastError": "Old problem"}"#
        let state = try JSONDecoder().decode(PersistedState.self, from: Data(legacy.utf8))
        XCTAssertEqual(state.errorRecords.map(\.message), ["Old problem"])
        XCTAssertFalse(state.launchAtLoginSeeded)
    }

    func testFreshInstallSkipsTheUpdaterNotice() {
        let fresh = StateStore(directory: root.appendingPathComponent("new"))
        XCTAssertTrue(fresh.isFreshInstall)
        XCTAssertTrue(fresh.state.triageIntroShown, "a new user has no old .txt scripts to retire")
    }

    // MARK: - Allowlist phones

    func testPhoneNumbersMatchWhateverFormatWasTyped() {
        let handle = "+15555550123"
        for typed in ["(555) 555-0123", "555.555.0123", "+1 555 555 0123", "15555550123", "+15555550123"] {
            XCTAssertTrue(AllowlistMatch.phonesMatch(typed, handle), typed)
        }
        XCTAssertFalse(AllowlistMatch.phonesMatch("555-0123", handle), "7 digits is not a full number")
        XCTAssertFalse(AllowlistMatch.phonesMatch("(555) 555-0199", handle))
        XCTAssertFalse(AllowlistMatch.phonesMatch("me@example.com", handle))
    }

    func testAllowlistStoresPhonesWithoutPunctuationAndFlagsJunk() {
        XCTAssertEqual(AllowlistInput.normalize("+1 (555) 555-0123"), "+15555550123")
        XCTAssertEqual(AllowlistInput.normalize("me@example.com"), "me@example.com")
        XCTAssertTrue(AllowlistMatch.looksLikeHandle("me@example.com"))
        XCTAssertTrue(AllowlistMatch.looksLikeHandle("(555) 555-0123"))
        XCTAssertFalse(AllowlistMatch.looksLikeHandle("Mom"))
    }

    func testFilterAcceptsFormattedAllowlistEntry() {
        var settings = Settings()
        settings.allowedHandles = ["(555) 555-0123"]
        let event = MessageEvent(
            rowid: 1, guid: "g", text: "hello", attributedBody: nil, dateAppleNs: 0,
            isFromMe: false, cacheHasAttachments: false, service: "iMessage",
            handleId: "+15555550123", chatGuid: "iMessage;-;+15555550123", chatStyle: 45, attachments: [])
        guard case .capture = MessageFilter.decide(event: event, selfHandles: [], settings: settings) else {
            return XCTFail("a formatted allowlist number must match the E.164 handle")
        }
    }

    // MARK: - Reply shapes stay filtered

    func testNewReplyShapesAreRecognizedAsOurOwn() throws {
        for count in 1...3 {
            let reply = try XCTUnwrap(Replier.composeReplyText(
                replyMode: .all, outcome: .success(URL(fileURLWithPath: "/n.md")), missingAttachments: count))
            XCTAssertTrue(MessageFilter.looksLikeAppConfirmation(reply), reply)
        }
        for offline in [true, false] {
            let reply = try XCTUnwrap(Replier.composeSpooledReplyText(replyMode: .all, destinationOffline: offline))
            XCTAssertTrue(MessageFilter.looksLikeAppConfirmation(reply), reply)
        }
        XCTAssertEqual(Replier.composeSpooledReplyText(replyMode: .all, destinationOffline: false),
                       "✅ Queued — waiting for an earlier note", "no false 'offline' claim while the drive is present")
    }

    // MARK: - Status line

    func testBlockedRepliesDoNotWarnWhenRepliesAreOff() {
        let on = MenuBarStatus.line(permission: .ok, automation: .required, paused: false, lastError: nil)
        XCTAssertEqual(on.kind, .automationNeeded)
        let off = MenuBarStatus.line(permission: .ok, automation: .required, paused: false, lastError: nil, repliesOff: true)
        XCTAssertEqual(off.kind, .capturing)
    }

    // MARK: - Late attachments

    func testRetrierCopiesALateAttachmentAndRebuildsTheFooter() async throws {
        let appState = AppState(supportDirectory: root.appendingPathComponent("support"))
        let notes = root.appendingPathComponent("Notes")
        try fm.createDirectory(at: notes, withIntermediateDirectories: true)
        let note = notes.appendingPathComponent("2026-09-29 Whiteboard.md")
        try "---\ntype: voice-note\n---\n\nphoto of the whiteboard\n".write(to: note, atomically: true, encoding: .utf8)
        let source = root.appendingPathComponent("IMG_0001.HEIC")
        let ref = AttachmentRef(sourcePath: source.path, mimeType: "image/heic", transferName: "IMG_0001.HEIC")
        let retrier = AttachmentRetrier(appState: appState, sleep: { _ in })

        let stillMissing = await retrier.attempt(noteURL: note, attachments: [ref])
        XCTAssertEqual(stillMissing, [ref], "not downloaded yet")

        try Data([0xFF]).write(to: source)
        let none = await retrier.attempt(noteURL: note, attachments: [ref])
        XCTAssertTrue(none.isEmpty)
        let text = try String(contentsOf: note, encoding: .utf8)
        XCTAssertEqual(text, "---\ntype: voice-note\n---\n\nphoto of the whiteboard\n\nAttachments:\n- [IMG_0001.HEIC](<2026-09-29 Whiteboard/IMG_0001.HEIC>)\n")
        XCTAssertTrue(fm.fileExists(atPath: notes.appendingPathComponent("2026-09-29 Whiteboard/IMG_0001.HEIC").path))
    }

    // MARK: - Undo a handoff

    func testUndoDeletesTheReminderOnceAndRecordsIt() async {
        let fake = FakeEventKitClient()
        let appState = AppState(supportDirectory: root.appendingPathComponent("undo"), eventKit: fake)
        appState.settings.update { $0.remindersHandoffEnabled = true }
        let manager = HandoffManager(appState: appState, client: fake, ledger: HandoffLedger(stateStore: appState.state))

        let outcome = await manager.process(text: "remind me to call the bank tomorrow", capturedAt: Date())
        XCTAssertTrue(outcome.reminderCreated)
        let row = try? XCTUnwrap(appState.activity.recent.first { $0.kind == .reminderCreated })
        XCTAssertEqual(row?.undo?.identifier, "reminder-1")

        guard let row else { return XCTFail("no reminder row") }
        XCTAssertNil(appState.undoHandoff(row))
        XCTAssertEqual(fake.deletedItems.map(\.identifier), ["reminder-1"])
        XCTAssertTrue(appState.activity.undoneIDs.contains(row.id))
        XCTAssertTrue(appState.activity.recent.first?.summary.hasPrefix("Removed the reminder") == true)

        XCTAssertNil(appState.undoHandoff(row))
        XCTAssertEqual(fake.deletedItems.count, 1, "a second Undo does nothing")
        XCTAssertTrue(ActivityLog(directory: root.appendingPathComponent("undo")).undoneIDs.contains(row.id),
                      "the undone state survives a relaunch")
    }

    // MARK: - Retries survive a restart

    func testSavedRetryResumesAndFinishesAfterRestart() async throws {
        let support = root.appendingPathComponent("retry-support")
        let notes = root.appendingPathComponent("RetryNotes")
        try fm.createDirectory(at: notes, withIntermediateDirectories: true)
        let note = notes.appendingPathComponent("2026-09-29 Receipt.txt")
        try "receipt photo".write(to: note, atomically: true, encoding: .utf8)
        let source = root.appendingPathComponent("IMG_0002.JPG")
        let ref = AttachmentRef(sourcePath: source.path, mimeType: nil, transferName: nil)

        // First run: the photo isn't there; the retry is saved, then the app "quits".
        let first = AppState(supportDirectory: support)
        let retrier = AttachmentRetrier(appState: first, sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
        retrier.schedule(noteURL: note, attachments: [ref])
        XCTAssertEqual(first.state.state.pendingAttachmentRetries.count, 1)
        retrier.cancelAll()

        // Relaunch after the photo downloaded, long after the schedule ended.
        try Data([0x01]).write(to: source)
        let later = Date().addingTimeInterval(AttachmentRetrier.schedule.last! + 60)
        let second = AppState(supportDirectory: support)
        XCTAssertEqual(second.state.state.pendingAttachmentRetries.count, 1, "the retry was saved to disk")
        let resumed = AttachmentRetrier(appState: second, sleep: { _ in }, clock: { later })
        resumed.resume()
        for _ in 0..<50 where !second.state.state.pendingAttachmentRetries.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(second.state.state.pendingAttachmentRetries.isEmpty)
        XCTAssertTrue(try String(contentsOf: note, encoding: .utf8).contains("IMG_0002.JPG"))
        XCTAssertEqual(second.activity.recent.first?.kind, .attachmentRecovered)
    }
}
