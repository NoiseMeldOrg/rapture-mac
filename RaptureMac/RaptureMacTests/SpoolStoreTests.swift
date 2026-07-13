import XCTest
@testable import Rapture

@MainActor
final class SpoolStoreTests: XCTestCase {
    private var root: URL!
    private var support: URL!
    private var stateStore: StateStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpoolStoreTests-\(UUID().uuidString)", isDirectory: true)
        support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        stateStore = StateStore(directory: support)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore(now: Date = Date()) -> SpoolStore {
        SpoolStore(
            directory: root.appendingPathComponent("Spool", isDirectory: true),
            stateStore: stateStore,
            clock: { now }
        )
    }

    func testAddThenItemsRoundTrip() async throws {
        let store = makeStore()
        let capturedAt = Date(timeIntervalSince1970: 1_750_000_000)
        try await store.add(text: "rent is due on the 5th", capturedAt: capturedAt, source: .raptureMac)

        let items = store.items()
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.metadata.source, .raptureMac)
        XCTAssertEqual(item.metadata.capturedAt.timeIntervalSince1970,
                       capturedAt.timeIntervalSince1970, accuracy: 1)
        let text = try String(contentsOf: item.captureTextURL, encoding: .utf8)
        XCTAssertEqual(text, "rent is due on the 5th")
    }

    func testAttachmentsCopiedIntoItem() async throws {
        let sourceFile = root.appendingPathComponent("photo.heic")
        try Data("img".utf8).write(to: sourceFile)

        let store = makeStore()
        let item = try await store.add(
            text: "with attachment",
            capturedAt: Date(),
            source: .raptureMac,
            attachments: [AttachmentRef(sourcePath: sourceFile.path, mimeType: nil, transferName: "photo.heic")]
        )

        let copied = item.attachmentsDirectory.appendingPathComponent("photo.heic")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
        XCTAssertTrue(item.metadata.failedAttachments.isEmpty)
    }

    func testMissingAttachmentRecordedNotFatal() async throws {
        let store = makeStore()
        let item = try await store.add(
            text: "attachment gone",
            capturedAt: Date(),
            source: .raptureMac,
            attachments: [AttachmentRef(sourcePath: root.appendingPathComponent("gone.jpg").path, mimeType: nil, transferName: nil)]
        )
        XCTAssertEqual(item.metadata.failedAttachments.count, 1)
        XCTAssertEqual(store.items().count, 1)
    }

    func testItemsSortedBySeqAndSeqIsMonotonic() async throws {
        let store = makeStore()
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        try await store.add(text: "first", capturedAt: base, source: .raptureMac)
        try await store.add(text: "second", capturedAt: base, source: .raptureMac) // same second
        try await store.add(text: "third", capturedAt: base.addingTimeInterval(60), source: .raptureMac)

        let texts = try store.items().map { try String(contentsOf: $0.captureTextURL, encoding: .utf8) }
        XCTAssertEqual(texts, ["first", "second", "third"])
        let seqs = store.items().map(\.metadata.seq)
        XCTAssertEqual(seqs, seqs.sorted())
        XCTAssertEqual(Set(seqs).count, 3)
    }

    func testSeqSurvivesDrainToEmptyAndReinstantiation() async throws {
        var store = makeStore()
        let first = try await store.add(text: "a", capturedAt: Date(), source: .raptureMac)
        store.remove(first)
        XCTAssertTrue(store.isEmpty)

        // New instance over the same state store: the persisted counter, not the
        // (now empty) directory, decides the next seq.
        store = makeStore()
        let second = try await store.add(text: "b", capturedAt: Date(), source: .raptureMac)
        XCTAssertGreaterThan(second.metadata.seq, first.metadata.seq)
        XCTAssertNotEqual(second.name, first.name)
    }

    func testSeqFloorsToExistingItemsWhenStateLost() async throws {
        let store = makeStore()
        let item = try await store.add(text: "queued", capturedAt: Date(), source: .raptureMac)

        // Simulate a lost state.json: counter resets to 1 but the item remains.
        stateStore.update { $0.spoolNextSeq = 1 }
        let next = try await store.add(text: "after reset", capturedAt: Date(), source: .raptureMac)
        XCTAssertGreaterThan(next.metadata.seq, item.metadata.seq)
    }

    func testUncommittedDebrisInvisibleToScan() async throws {
        let store = makeStore()
        try await store.add(text: "real", capturedAt: Date(), source: .raptureMac)

        let spoolDir = root.appendingPathComponent("Spool", isDirectory: true)
        // Dot-prefixed staging dir.
        try FileManager.default.createDirectory(
            at: spoolDir.appendingPathComponent(".staging-00000099-x", isDirectory: true),
            withIntermediateDirectories: true
        )
        // Committed-looking dir without meta.json.
        try FileManager.default.createDirectory(
            at: spoolDir.appendingPathComponent("00000098-no-meta", isDirectory: true),
            withIntermediateDirectories: true
        )
        // Stray file at the root.
        try Data().write(to: spoolDir.appendingPathComponent("stray.txt"))

        XCTAssertEqual(store.items().count, 1)
    }

    func testRemoveDeletesItemIncludingAttachments() async throws {
        let sourceFile = root.appendingPathComponent("clip.m4a")
        try Data("audio".utf8).write(to: sourceFile)

        let store = makeStore()
        let item = try await store.add(
            text: "note",
            capturedAt: Date(),
            source: .raptureMac,
            attachments: [AttachmentRef(sourcePath: sourceFile.path, mimeType: nil, transferName: nil)]
        )
        store.remove(item)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.directory.path))
        XCTAssertTrue(store.isEmpty)
    }
}
