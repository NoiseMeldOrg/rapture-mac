import XCTest
@testable import Rapture

/// The flush must file a spooled capture exactly as a live write would have —
/// same contract, same conventions — with `captured`/`source` taken verbatim
/// from the item's metadata.
@MainActor
final class SpoolFlusherTests: XCTestCase {

    private var root: URL!
    private var output: URL!
    private var support: URL!
    private var stateStore: StateStore!
    private var store: SpoolStore!
    private let fm = FileManager.default

    /// Apple epoch, so live-write goldens are deterministic (2001-01-01T00:00:00Z).
    private let capturedAt = Date(timeIntervalSince1970: MessageEvent.appleEpochOffsetSeconds)

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("spool-flusher-\(UUID().uuidString)", isDirectory: true)
        output = root.appendingPathComponent("Rapture Notes", isDirectory: true)
        support = root.appendingPathComponent("support", isDirectory: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        stateStore = StateStore(directory: support)
        store = SpoolStore(directory: root.appendingPathComponent("Spool", isDirectory: true), stateStore: stateStore)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func liveWrite(text: String, mode: TriageMode, into folder: URL) async -> WriteResult {
        let captured = CapturedMessage(
            event: MessageEvent(
                rowid: 1, guid: "guid-\(UUID().uuidString)", text: text, attributedBody: nil,
                dateAppleNs: 0, isFromMe: false, cacheHasAttachments: false,
                service: "iMessage", handleId: "+15555550100",
                chatGuid: "iMessage;-;chat", chatStyle: 45, attachments: []
            ),
            decodedText: text,
            isCatchup: false
        )
        return await FileWriter().write(captured, to: folder, mode: mode)
    }

    private func onlyFile(under url: URL) throws -> URL {
        let all = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        XCTAssertEqual(all.count, 1, "expected exactly one entry in \(url.path)")
        return all[0]
    }

    // MARK: - Full mode

    func testFullModeByteEqualsLiveTriagedWrite() async throws {
        let text = "rent is due on the 5th"

        let liveFolder = root.appendingPathComponent("live", isDirectory: true)
        _ = await liveWrite(text: text, mode: .full, into: liveFolder)
        let liveNote = try onlyFile(under: liveFolder.appendingPathComponent("Notes"))

        let item = try await store.add(text: text, capturedAt: capturedAt, source: .raptureMac)
        let result = await SpoolFlusher().file(item, to: output, mode: .full)
        XCTAssertTrue(result.isSuccess)
        let flushedNote = try onlyFile(under: output.appendingPathComponent("Notes"))

        XCTAssertEqual(flushedNote.lastPathComponent, liveNote.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: flushedNote), try Data(contentsOf: liveNote))
    }

    func testFullModeUsesMetadataSourceVerbatim() async throws {
        let item = try await store.add(text: "from the phone", capturedAt: capturedAt, source: .raptureIOS)
        let result = await SpoolFlusher().file(item, to: output, mode: .full)
        XCTAssertTrue(result.isSuccess)
        let note = try onlyFile(under: output.appendingPathComponent("Notes"))
        let contents = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(contents.contains("source: rapture-ios"), "got: \(contents)")
    }

    func testFullModeLinkFilesIntoLinks() async throws {
        let url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        let item = try await store.add(text: url, capturedAt: capturedAt, source: .raptureMac)
        let result = await SpoolFlusher().file(item, to: output, mode: .full)
        XCTAssertTrue(result.isSuccess)
        let note = try onlyFile(under: output.appendingPathComponent("Links"))
        let contents = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(contents.contains("type: youtube-link"))
        XCTAssertTrue(contents.contains("raw_media: \(url)"))
    }

    // MARK: - Raw mode

    func testRawModeByteEqualsLiveRawWrite() async throws {
        let text = "plain escape hatch capture"

        let liveFolder = root.appendingPathComponent("live", isDirectory: true)
        _ = await liveWrite(text: text, mode: .raw, into: liveFolder)
        let liveTxt = try onlyFile(under: liveFolder)

        let item = try await store.add(text: text, capturedAt: capturedAt, source: .raptureMac)
        let result = await SpoolFlusher().file(item, to: output, mode: .raw)
        XCTAssertTrue(result.isSuccess)
        let flushedTxt = try onlyFile(under: output)

        XCTAssertEqual(flushedTxt.lastPathComponent, liveTxt.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: flushedTxt), try Data(contentsOf: liveTxt))
    }

    // MARK: - Attachments

    func testAttachmentsFollowTheNoteWithFooter() async throws {
        let sourceFile = root.appendingPathComponent("photo.heic")
        try Data("img".utf8).write(to: sourceFile)
        let item = try await store.add(
            text: "note with photo",
            capturedAt: capturedAt,
            source: .raptureMac,
            attachments: [AttachmentRef(sourcePath: sourceFile.path, mimeType: nil, transferName: "photo.heic")]
        )

        let result = await SpoolFlusher().file(item, to: output, mode: .full)
        XCTAssertTrue(result.isSuccess)
        XCTAssertTrue(result.failedAttachments.isEmpty)

        let notesDir = output.appendingPathComponent("Notes")
        let entries = try fm.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: nil)
        let note = try XCTUnwrap(entries.first { $0.pathExtension == "md" })
        let attachmentDir = try XCTUnwrap(entries.first { $0.pathExtension != "md" })
        XCTAssertEqual(attachmentDir.lastPathComponent, note.deletingPathExtension().lastPathComponent)
        XCTAssertTrue(fm.fileExists(atPath: attachmentDir.appendingPathComponent("photo.heic").path))
        let contents = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(contents.contains("photo.heic"))
    }

    func testSpoolTimeFailedAttachmentsReportedOnFlush() async throws {
        let item = try await store.add(
            text: "attachment was gone at spool time",
            capturedAt: capturedAt,
            source: .raptureMac,
            attachments: [AttachmentRef(sourcePath: root.appendingPathComponent("gone.jpg").path, mimeType: nil, transferName: nil)]
        )
        let result = await SpoolFlusher().file(item, to: output, mode: .full)
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.failedAttachments.count, 1)
    }

    // MARK: - Collisions and unavailability

    func testCollisionTakesSuffix() async throws {
        let text = "same text same second"
        let first = try await store.add(text: text, capturedAt: capturedAt, source: .raptureMac)
        let second = try await store.add(text: text, capturedAt: capturedAt, source: .raptureMac)

        let flusher = SpoolFlusher()
        let firstResult = await flusher.file(first, to: output, mode: .full)
        let secondResult = await flusher.file(second, to: output, mode: .full)
        XCTAssertTrue(firstResult.isSuccess)
        XCTAssertTrue(secondResult.isSuccess)

        let notes = try fm.contentsOfDirectory(at: output.appendingPathComponent("Notes"), includingPropertiesForKeys: nil)
            .map(\.lastPathComponent).sorted()
        XCTAssertEqual(notes.count, 2)
        XCTAssertTrue(notes.contains { $0.hasSuffix("-1.md") }, "got \(notes)")
    }

    func testAbsentVolumeReturnsUnavailableWithoutWriting() async throws {
        let item = try await store.add(text: "queued", capturedAt: capturedAt, source: .raptureMac)
        let absentGuard = DestinationGuard(directoryExists: { _ in false }, isVolumeRoot: { _ in false })
        let phantom = URL(fileURLWithPath: "/Volumes/RaptureFlushTest-\(UUID().uuidString)/Notes")

        let result = await SpoolFlusher(destinationGuard: absentGuard).file(item, to: phantom, mode: .full)

        guard case .unavailable = result.outcome else {
            return XCTFail("expected .unavailable, got \(result.outcome)")
        }
        XCTAssertFalse(fm.fileExists(atPath: phantom.path))
    }
}

@MainActor
final class SpoolFiledLedgerTests: XCTestCase {

    func testAppendAndMatch() {
        let now = Date()
        var entries: [SpoolFiledEntry] = []
        entries = SpoolFiledLedger.appendEntry(into: entries, itemName: "00000001-x", now: now)
        XCTAssertTrue(SpoolFiledLedger.matches(entries: entries, itemName: "00000001-x", now: now))
        XCTAssertFalse(SpoolFiledLedger.matches(entries: entries, itemName: "00000002-y", now: now))
    }

    func testTTLExpiry() {
        let now = Date()
        let entries = SpoolFiledLedger.appendEntry(into: [], itemName: "00000001-x", now: now)
        let later = now.addingTimeInterval(SpoolFiledLedger.ttl + 1)
        XCTAssertFalse(SpoolFiledLedger.matches(entries: entries, itemName: "00000001-x", now: later))
    }

    func testCapacityEvictsOldestFirst() {
        let now = Date()
        var entries: [SpoolFiledEntry] = []
        for index in 0...(SpoolFiledLedger.capacity) {
            entries = SpoolFiledLedger.appendEntry(into: entries, itemName: "item-\(index)", now: now)
        }
        XCTAssertEqual(entries.count, SpoolFiledLedger.capacity)
        XCTAssertFalse(SpoolFiledLedger.matches(entries: entries, itemName: "item-0", now: now))
        XCTAssertTrue(SpoolFiledLedger.matches(entries: entries, itemName: "item-\(SpoolFiledLedger.capacity)", now: now))
    }

    func testRecordPersistsThroughStateStore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spool-ledger-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(directory: dir)
        let ledger = SpoolFiledLedger(stateStore: store)

        ledger.record(itemName: "00000042-2026-07-13T14-00-00Z")
        XCTAssertTrue(ledger.contains(itemName: "00000042-2026-07-13T14-00-00Z"))

        // A fresh store over the same directory sees the persisted entry.
        let reloaded = StateStore(directory: dir)
        XCTAssertTrue(SpoolFiledLedger(stateStore: reloaded).contains(itemName: "00000042-2026-07-13T14-00-00Z"))
    }
}
