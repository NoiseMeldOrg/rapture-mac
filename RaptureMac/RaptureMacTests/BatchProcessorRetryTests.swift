import XCTest
@testable import Rapture

/// A failed iMessage write must never lose the capture. Before 1.0.126 the
/// row's guid was remembered before the write, so the replay of a failed row
/// looked like a duplicate and the watermark moved past it: one ✗ reply, then
/// the note was gone. These tests pin retry, watermark hold, reply-once,
/// rescue after the give-up window, and the self-handle wait.
@MainActor
final class BatchProcessorRetryTests: XCTestCase {

    private let fm = FileManager.default
    private var root: URL!
    private var output: URL!
    private var support: URL!
    private var spoolDir: URL!
    private let availableGuard = DestinationGuard(directoryExists: { _ in true }, isVolumeRoot: { _ in true })

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("batch-retry-\(UUID().uuidString)", isDirectory: true)
        output = root.appendingPathComponent("Notes", isDirectory: true)
        support = root.appendingPathComponent("Support", isDirectory: true)
        spoolDir = root.appendingPathComponent("Spool", isDirectory: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
    }

    // MARK: - Harness

    private final class FakeSender: AppleScriptSending, @unchecked Sendable {
        var sent: [String] = []
        func send(text: String, toChatGuid chatGuid: String) async throws { sent.append(text) }
    }

    private final class FakeNotifications: NotificationDispatching, @unchecked Sendable {
        func send(title: String, body: String) async {}
    }

    /// Fails while `failing` is true; records every call.
    private final class ScriptedWriter: FileWriting, @unchecked Sendable {
        var failing = true
        var failedAttachments: [String] = []
        var writtenRowids: [Int64] = []
        let output: URL
        init(output: URL) { self.output = output }
        func write(_ captured: CapturedMessage, to folder: URL, mode: TriageMode) async -> WriteResult {
            writtenRowids.append(captured.event.rowid)
            if failing { return WriteResult(outcome: .failure(reason: "Disk full"), failedAttachments: []) }
            return WriteResult(
                outcome: .success(output.appendingPathComponent("note-\(captured.event.rowid).md")),
                failedAttachments: failedAttachments)
        }
    }

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func makeAppState() -> AppState {
        let appState = AppState(supportDirectory: support)
        appState.settings.update {
            $0.outputFolder = output
            $0.paused = false
            $0.triageMode = .full
            $0.replyMode = .all
        }
        appState.state.update { $0.automationPrePromptShown = true }
        return appState
    }

    private func makeProcessor(
        appState: AppState,
        writer: FileWriting,
        sender: FakeSender,
        clock: Clock,
        handles: @escaping @MainActor () -> Set<String> = { ["+15555550100"] },
        refresh: (@MainActor () async -> Set<String>)? = nil
    ) -> BatchProcessor {
        let replier = Replier(
            sender: sender,
            echoGuard: EchoGuard(stateStore: appState.state),
            notifications: FakeNotifications(),
            stateStore: appState.state,
            appState: appState,
            prePromptHandler: { true }
        )
        return BatchProcessor(
            appState: appState,
            writer: writer,
            replier: replier,
            echoGuard: EchoGuard(stateStore: appState.state),
            contentDedupCache: ContentDedupCache(stateStore: appState.state),
            spool: SpoolStore(directory: spoolDir, stateStore: appState.state),
            destinationGuard: availableGuard,
            selfHandlesProvider: handles,
            selfChatGuidProvider: { nil },
            advanceWatermark: { [weak appState] rowid in
                appState?.state.update { $0.chatDbWatermark = max($0.chatDbWatermark, rowid) }
            },
            refreshSelfHandles: refresh,
            clock: { clock.now }
        )
    }

    private func event(_ rowid: Int64, _ text: String) -> MessageEvent {
        MessageEvent(
            rowid: rowid, guid: "guid-\(rowid)", text: text, attributedBody: nil,
            dateAppleNs: rowid * 1_000_000_000, isFromMe: false, cacheHasAttachments: false,
            service: "iMessage", handleId: "+15555550100", chatGuid: "iMessage;-;chat-self",
            chatStyle: 45, attachments: []
        )
    }

    // MARK: - Retry

    func testFailedWriteIsRetriedAfterBackoffAndRepliesOnlyOnce() async {
        let appState = makeAppState()
        let writer = ScriptedWriter(output: output)
        let sender = FakeSender()
        let clock = Clock()
        let processor = makeProcessor(appState: appState, writer: writer, sender: sender, clock: clock)
        let batch = [event(5, "rent is due on the 5th")]

        let first = await processor.process(batch: batch)
        XCTAssertEqual(first.failureCount, 1)
        XCTAssertEqual(appState.state.state.chatDbWatermark, 0, "a failed row holds the watermark")
        XCTAssertEqual(appState.lastError, "Disk full")

        // The watcher re-yields the same row every second meanwhile.
        clock.now += 1
        _ = await processor.process(batch: batch)
        XCTAssertEqual(writer.writtenRowids, [5], "inside the backoff the row waits, no second write")
        XCTAssertEqual(appState.state.state.chatDbWatermark, 0)

        clock.now += BatchProcessor.failureRetryBackoff
        _ = await processor.process(batch: batch)
        XCTAssertEqual(writer.writtenRowids, [5, 5], "retried after the backoff")
        XCTAssertEqual(sender.sent, ["✗ Disk full"], "the failure reply goes out once, not per attempt")

        writer.failing = false
        clock.now += BatchProcessor.failureRetryBackoff
        let last = await processor.process(batch: batch)
        XCTAssertEqual(last.successCount, 1, "the note is filed, not lost")
        XCTAssertEqual(appState.state.state.chatDbWatermark, 5)
        XCTAssertNil(appState.lastError, "success clears the capture error")
        XCTAssertEqual(sender.sent, ["✗ Disk full", "✅ Saved"])
        XCTAssertTrue(appState.activity.recent.first?.summary.contains("filed on retry") == true)
    }

    func testLaterRowsFileButWatermarkStaysBelowTheFailedRow() async {
        let appState = makeAppState()
        let writer = ScriptedWriter(output: output)
        let clock = Clock()
        let processor = makeProcessor(appState: appState, writer: writer, sender: FakeSender(), clock: clock)

        // Row 5 fails; row 6 succeeds in the same batch.
        final class FailFive: FileWriting, @unchecked Sendable {
            let inner: ScriptedWriter
            init(_ inner: ScriptedWriter) { self.inner = inner }
            func write(_ captured: CapturedMessage, to folder: URL, mode: TriageMode) async -> WriteResult {
                inner.failing = captured.event.rowid == 5
                return await inner.write(captured, to: folder, mode: mode)
            }
        }
        let mixed = makeProcessor(appState: appState, writer: FailFive(writer), sender: FakeSender(), clock: clock)
        _ = processor
        let batch = [event(5, "first note"), event(6, "second note")]

        _ = await mixed.process(batch: batch)
        XCTAssertEqual(writer.writtenRowids, [5, 6])
        XCTAssertEqual(appState.state.state.chatDbWatermark, 0, "row 6 may not carry the watermark past row 5")

        // Replay: row 6 is remembered (no second file), row 5 is retried.
        clock.now += BatchProcessor.failureRetryBackoff
        _ = await mixed.process(batch: batch)
        XCTAssertEqual(writer.writtenRowids, [5, 6, 5], "row 6 never files twice")
        XCTAssertEqual(appState.state.state.chatDbWatermark, 0, "still held while row 5 fails")
    }

    func testGivesUpAfterWindowAndRescuesTheText() async throws {
        let appState = makeAppState()
        let writer = ScriptedWriter(output: output)
        let clock = Clock()
        let processor = makeProcessor(appState: appState, writer: writer, sender: FakeSender(), clock: clock)
        let batch = [event(9, "the words that must survive")]

        _ = await processor.process(batch: batch)
        clock.now += BatchProcessor.giveUpAfter + 1
        _ = await processor.process(batch: batch)

        XCTAssertEqual(appState.state.state.chatDbWatermark, 9, "released after the give-up window")
        let rescueDir = support.appendingPathComponent("Failed captures")
        let files = try fm.contentsOfDirectory(atPath: rescueDir.path)
        XCTAssertEqual(files.count, 1)
        let text = try String(contentsOf: rescueDir.appendingPathComponent(files[0]), encoding: .utf8)
        XCTAssertEqual(text, "the words that must survive")
        XCTAssertTrue(appState.lastError?.contains("Gave up") == true)
        XCTAssertEqual(appState.activity.recent.first?.kind, .gaveUp)
    }

    // MARK: - Missing attachments

    func testMissingAttachmentIsNamedInTheReplyAndErrorOutlivesOtherSuccesses() async {
        let appState = makeAppState()
        let writer = ScriptedWriter(output: output)
        writer.failing = false
        writer.failedAttachments = ["/tmp/IMG_0001.HEIC"]
        let sender = FakeSender()
        let processor = makeProcessor(appState: appState, writer: writer, sender: sender, clock: Clock())

        _ = await processor.process(batch: [event(3, "photo of the whiteboard")])
        XCTAssertEqual(sender.sent, ["✅ Saved · 1 attachment missing"])
        XCTAssertTrue(appState.lastError?.contains("not downloaded yet") == true)

        writer.failedAttachments = []
        _ = await processor.process(batch: [event(4, "unrelated note")])
        XCTAssertTrue(appState.lastError?.contains("not downloaded yet") == true,
                      "an unrelated success must not hide the missing attachment")
    }

    // MARK: - Self handles

    func testWaitsForSelfHandlesInsteadOfDroppingTheFirstNote() async {
        let appState = makeAppState()
        let writer = ScriptedWriter(output: output)
        writer.failing = false
        let clock = Clock()
        final class Box: @unchecked Sendable { var handles: Set<String> = [] }
        let box = Box()
        let processor = makeProcessor(
            appState: appState, writer: writer, sender: FakeSender(), clock: clock,
            handles: { box.handles },
            refresh: { box.handles }
        )
        let batch = [event(2, "my very first test note")]

        let held = await processor.process(batch: batch)
        XCTAssertEqual(held.droppedCount, 0, "not dropped as not-allowlisted")
        XCTAssertEqual(appState.state.state.chatDbWatermark, 0)

        // The sent copy syncs in; the next lookup finds the user's address.
        box.handles = ["+15555550100"]
        clock.now += BatchProcessor.selfHandleRefreshInterval
        let filed = await processor.process(batch: batch)
        XCTAssertEqual(filed.successCount, 1)
        XCTAssertEqual(appState.state.state.chatDbWatermark, 2)
    }

    func testSelfHandleWaitIsBounded() async {
        let appState = makeAppState()
        let clock = Clock()
        let processor = makeProcessor(
            appState: appState, writer: ScriptedWriter(output: output), sender: FakeSender(), clock: clock,
            handles: { [] }, refresh: { [] }
        )
        _ = await processor.process(batch: [event(2, "from a stranger")])
        clock.now += BatchProcessor.selfHandleGrace + 1
        let later = await processor.process(batch: [event(2, "from a stranger")])
        XCTAssertEqual(later.droppedCount, 1, "after the grace the allowlist alone decides")
        XCTAssertEqual(appState.state.state.chatDbWatermark, 2)
    }
}
