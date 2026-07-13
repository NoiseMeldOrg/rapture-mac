import XCTest
@testable import Rapture

/// Cross-cutting safety invariants around the output folder: create-if-absent never
/// wipes, a missing source never clobbers a populated destination, the writer's
/// folder (re)creation is non-destructive, and the new `seedScaffold` setting is
/// forward/backward compatible with existing `settings.json`.
@MainActor
final class OutputFolderSafetyTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("safety-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root, fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
    }

    private func makeDir(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func event(text: String) -> MessageEvent {
        MessageEvent(
            rowid: 1,
            guid: "guid-\(UUID().uuidString)",
            text: text,
            attributedBody: nil,
            dateAppleNs: 0,
            isFromMe: false,
            cacheHasAttachments: false,
            service: "iMessage",
            handleId: "+15555550100",
            chatGuid: "iMessage;-;chat",
            chatStyle: 45,
            attachments: []
        )
    }

    // MARK: - Writer creates a missing folder without wiping an existing one

    func testWriterCreatesMissingFolderAndWritesNote() async throws {
        // The exact mechanism that recreated the bare folder on 2026-06-23: a capture
        // arrives and the configured folder is absent. Documented as expected behavior.
        let folder = root.appendingPathComponent("Rapture Notes", isDirectory: true)
        XCTAssertFalse(fm.fileExists(atPath: folder.path))

        let result = await FileWriter().write(
            CapturedMessage(event: event(text: "hello"), decodedText: "hello", isCatchup: false),
            to: folder,
            mode: .full
        )

        if case .failure(let reason) = result.outcome {
            XCTFail("write should succeed, got failure: \(reason)")
        }
        XCTAssertTrue(fm.fileExists(atPath: folder.path), "writer recreates the missing folder")
    }

    func testWriterPreservesExistingFolderContents() async throws {
        // create-if-absent must NOT replace or wipe an existing, populated folder.
        let folder = try makeDir("Rapture Notes")
        try "my routing rules".write(to: folder.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        _ = try makeDir("Rapture Notes/processed/2026-06")
        try "older".write(to: folder.appendingPathComponent("processed/2026-06/old.txt"), atomically: true, encoding: .utf8)

        _ = await FileWriter().write(
            CapturedMessage(event: event(text: "new note"), decodedText: "new note", isCatchup: false),
            to: folder,
            mode: .full
        )

        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("CLAUDE.md"), encoding: .utf8),
                       "my routing rules", "existing CLAUDE.md survives a write")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("processed/2026-06/old.txt"), encoding: .utf8),
                       "older", "existing processed/ history survives a write")
    }

    // MARK: - A missing source never clobbers a populated destination

    func testMigrateFromMissingSourceLeavesDestinationIntact() throws {
        let missingOld = root.appendingPathComponent("gone", isDirectory: true)
        let new = try makeDir("new")
        try "keep".write(to: new.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        try "note".write(to: new.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        // Source doesn't exist: migrate ensures the destination exists and returns,
        // touching nothing already in it.
        try OutputFolderMigrator(fileManager: fm).migrate(from: missingOld, to: new, strategy: .move)

        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("CLAUDE.md"), encoding: .utf8), "keep")
        XCTAssertEqual(try String(contentsOf: new.appendingPathComponent("a.txt"), encoding: .utf8), "note")
    }

    // MARK: - Settings forward/backward compatibility for seedScaffold

    func testDecodingLegacySettingsWithoutSeedScaffoldDefaultsOffAndKeepsFolder() throws {
        // A settings.json written before seedScaffold existed must still decode, default
        // the flag off, and — critically — preserve outputFolder (so an upgrade never
        // resets the folder and triggers a default-folder recreation).
        let legacy = """
        {
          "allowSMS": true,
          "allowedHandles": [],
          "launchAtLogin": true,
          "outputFolder": "file:///Users/example/Documents/Rapture%20Notes/",
          "paused": false,
          "replyMode": "all"
        }
        """
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(legacy.utf8))

        XCTAssertFalse(decoded.seedScaffold, "absent key defaults off")
        XCTAssertEqual(decoded.outputFolder?.path, "/Users/example/Documents/Rapture Notes")
        XCTAssertTrue(decoded.allowSMS)
        XCTAssertEqual(decoded.replyMode, .all)
    }

    func testSeedScaffoldSurvivesCodableRoundTrip() throws {
        let settings = Settings(outputFolder: root, seedScaffold: true)
        let data = try JSONEncoder().encode(settings)
        let reloaded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertTrue(reloaded.seedScaffold)
    }
}
