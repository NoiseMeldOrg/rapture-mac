import XCTest
@testable import Rapture

/// Compose-direct triage in `RelayFiler`: full mode files relay arrivals as contract
/// notes (iOS-derived titles preserved), and orphan audio honors a preferred
/// directory so late audio lands next to its triaged note.
@MainActor
final class RelayFilerTriageTests: XCTestCase {

    private let fm = FileManager.default
    private var relay: URL!
    private var output: URL!
    private var filer: RelayFiler!

    private let baseName = "2026-07-06T15-14-42Z Grocery Ideas"
    private var txtName: String { baseName + ".txt" }
    private var m4aName: String { baseName + ".m4a" }

    override func setUpWithError() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("relay-triage-\(UUID().uuidString)", isDirectory: true)
        relay = root.appendingPathComponent("Relay", isDirectory: true)
        output = root.appendingPathComponent("Rapture Notes", isDirectory: true)
        try fm.createDirectory(at: relay, withIntermediateDirectories: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        filer = RelayFiler()
    }

    override func tearDownWithError() throws {
        let root = relay.deletingLastPathComponent()
        if fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
    }

    private func makeCandidate(body: String, withAudio: Bool = false) throws -> RelayCandidate {
        let txtURL = relay.appendingPathComponent(txtName)
        try body.write(to: txtURL, atomically: true, encoding: .utf8)
        var audioURL: URL?
        if withAudio {
            let url = relay.appendingPathComponent(m4aName)
            try Data([0x00, 0x01]).write(to: url)
            audioURL = url
        }
        return RelayCandidate(txtURL: txtURL, audioURL: audioURL, relayFilename: txtName, baseName: baseName)
    }

    private func mdFiles(in subfolder: String) throws -> [URL] {
        let dir = output.appendingPathComponent(subfolder, isDirectory: true)
        guard fm.fileExists(atPath: dir.path) else { return [] }
        return try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
    }

    // MARK: - Full mode

    func testRelayNoteFilesAsContractWithIOSTitle() async throws {
        let candidate = try makeCandidate(body: "Milk and eggs")

        let result = await filer.file(candidate, to: output, mode: .full)

        XCTAssertTrue(result.isSuccess)
        let note = try XCTUnwrap(mdFiles(in: "Notes").first)
        let name = note.lastPathComponent
        XCTAssertTrue(name.hasSuffix(" Grocery Ideas.md"), "iOS-derived title survives; got \(name)")
        XCTAssertNotNil(name.range(of: #"^\d{4}-\d{2}-\d{2} "#, options: .regularExpression),
                        "filename leads with the local capture date")

        let contents = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(contents.contains("captured: 2026-07-06T15:14:42Z"))
        XCTAssertTrue(contents.contains("source: rapture-ios"))
        XCTAssertTrue(contents.contains("type: voice-note"))
        XCTAssertTrue(contents.contains("Milk and eggs"), "body lands verbatim")
    }

    func testRelayLinkFilesIntoLinksKeepingIOSTitle() async throws {
        let url = "https://youtu.be/dQw4w9WgXcQ"
        let candidate = try makeCandidate(body: url)

        let result = await filer.file(candidate, to: output, mode: .full)

        XCTAssertTrue(result.isSuccess)
        let note = try XCTUnwrap(mdFiles(in: "Links").first)
        XCTAssertTrue(note.lastPathComponent.hasSuffix(" Grocery Ideas.md"))
        let contents = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(contents.contains("type: youtube-link"))
        XCTAssertTrue(contents.contains("raw_media: \(url)"))
        XCTAssertEqual(result.link?.type, .youtubeLink, "enrichment echo set for link captures")
        XCTAssertEqual(result.link?.rawMedia, url)
    }

    func testVoiceNoteCarriesNoEnrichmentEcho() async throws {
        let candidate = try makeCandidate(body: "Milk and eggs")
        let result = await filer.file(candidate, to: output, mode: .full)
        XCTAssertTrue(result.isSuccess)
        XCTAssertNil(result.link)
    }

    func testAudioLandsInNoteNamedFolderWithMarkdownFooter() async throws {
        let candidate = try makeCandidate(body: "Milk and eggs", withAudio: true)

        let result = await filer.file(candidate, to: output, mode: .full)

        XCTAssertTrue(result.isSuccess)
        XCTAssertTrue(result.failedAttachments.isEmpty)
        let note = try XCTUnwrap(mdFiles(in: "Notes").first)
        let base = note.deletingPathExtension().lastPathComponent
        XCTAssertTrue(
            fm.fileExists(atPath: output.appendingPathComponent("Notes/\(base)/\(m4aName)").path),
            "audio lands in the note's own attachment folder"
        )
        let contents = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(contents.contains("Attachments:\n- [\(m4aName)](<\(base)/\(m4aName)>)"))
    }

    // MARK: - Orphan audio placement

    func testOrphanAudioUsesPreferredDirectoryEvenWhenItExists() async throws {
        let noteDir = output.appendingPathComponent("Notes/2026-07-06 Grocery Ideas", isDirectory: true)
        try fm.createDirectory(at: noteDir, withIntermediateDirectories: true)
        try Data([0x01]).write(to: noteDir.appendingPathComponent("existing.jpg"))
        let audioURL = relay.appendingPathComponent(m4aName)
        try Data([0x0A]).write(to: audioURL)

        let result = await filer.fileOrphanAudio(at: audioURL, to: output, preferredDirectory: noteDir)

        XCTAssertTrue(result.isSuccess)
        XCTAssertTrue(fm.fileExists(atPath: noteDir.appendingPathComponent(m4aName).path),
                      "the note's own folder is the target, never a collision")
        XCTAssertTrue(fm.fileExists(atPath: noteDir.appendingPathComponent("existing.jpg").path))
    }

    func testOrphanAudioFallsBackWhenPreferredPathIsAFile() async throws {
        let blocked = output.appendingPathComponent("Notes/blocked", isDirectory: false)
        try fm.createDirectory(at: output.appendingPathComponent("Notes", isDirectory: true), withIntermediateDirectories: true)
        try Data([0x01]).write(to: blocked)
        let audioURL = relay.appendingPathComponent(m4aName)
        try Data([0x0A]).write(to: audioURL)

        let result = await filer.fileOrphanAudio(at: audioURL, to: output, preferredDirectory: blocked)

        XCTAssertTrue(result.isSuccess)
        XCTAssertTrue(
            fm.fileExists(atPath: output.appendingPathComponent(baseName, isDirectory: true).appendingPathComponent(m4aName).path),
            "a file squatting on the preferred path falls back to the legacy root placement"
        )
    }
}
