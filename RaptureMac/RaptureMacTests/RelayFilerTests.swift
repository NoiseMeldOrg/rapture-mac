import XCTest
@testable import Rapture

/// Temp-dir integration tests for relay filing: verbatim bodies, the Attachments
/// footer convention, collision handling, and orphan-audio placement.
@MainActor
final class RelayFilerTests: XCTestCase {

    private let fm = FileManager.default
    private var relay: URL!
    private var output: URL!
    private var filer: RelayFiler!

    private let baseName = "2026-07-06T15-14-42Z Grocery Ideas"
    private var txtName: String { baseName + ".txt" }
    private var m4aName: String { baseName + ".m4a" }

    override func setUpWithError() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("relay-filer-\(UUID().uuidString)", isDirectory: true)
        relay = root.appendingPathComponent("Relay", isDirectory: true)
        output = root.appendingPathComponent("Notes", isDirectory: true)
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

    private func makeCandidate(body: String = "# Grocery Ideas\n\nMilk and eggs", withAudio: Bool = false) throws -> RelayCandidate {
        let txtURL = relay.appendingPathComponent(txtName)
        try body.write(to: txtURL, atomically: true, encoding: .utf8)
        var audioURL: URL?
        if withAudio {
            let url = relay.appendingPathComponent(m4aName)
            try Data([0x00, 0x01, 0x02]).write(to: url)
            audioURL = url
        }
        return RelayCandidate(txtURL: txtURL, audioURL: audioURL, relayFilename: txtName, baseName: baseName)
    }

    // MARK: - Verbatim filing

    func testFilesTxtVerbatim() async throws {
        let body = "# Grocery Ideas\n\nMilk and eggs"
        let candidate = try makeCandidate(body: body)

        let result = await filer.file(candidate, to: output, mode: .raw)

        XCTAssertTrue(result.isSuccess)
        let filed = output.appendingPathComponent(txtName)
        XCTAssertEqual(try String(contentsOf: filed, encoding: .utf8), body,
                       "the note body must land byte-identical, under the relay basename")
    }

    func testAppendsAttachmentsFooterWhenAudioPaired() async throws {
        let body = "# Grocery Ideas\n\nMilk and eggs"
        let candidate = try makeCandidate(body: body, withAudio: true)

        let result = await filer.file(candidate, to: output, mode: .raw)

        XCTAssertTrue(result.isSuccess)
        XCTAssertTrue(result.failedAttachments.isEmpty)
        let filedBody = try String(contentsOf: output.appendingPathComponent(txtName), encoding: .utf8)
        XCTAssertEqual(filedBody, body + "\n\nAttachments:\n- \(baseName)/\(m4aName)\n",
                       "paired audio gets the existing Attachments footer")
        let filedAudio = output.appendingPathComponent(baseName, isDirectory: true).appendingPathComponent(m4aName)
        XCTAssertTrue(fm.fileExists(atPath: filedAudio.path), "audio lands in the sibling attachment folder")
    }

    // MARK: - Collisions

    func testCollisionAppendsSuffixAgainstExistingTxt() async throws {
        try "already here".write(to: output.appendingPathComponent(txtName), atomically: true, encoding: .utf8)
        let candidate = try makeCandidate(body: "new body")

        let result = await filer.file(candidate, to: output, mode: .raw)

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent(txtName), encoding: .utf8), "already here",
                       "an existing note is never overwritten")
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent(baseName + "-1.txt"), encoding: .utf8), "new body")
    }

    func testCollisionAppendsSuffixAgainstExistingDirectory() async throws {
        try fm.createDirectory(at: output.appendingPathComponent(baseName, isDirectory: true), withIntermediateDirectories: true)
        let candidate = try makeCandidate(body: "new body")

        let result = await filer.file(candidate, to: output, mode: .raw)

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent(baseName + "-1.txt"), encoding: .utf8), "new body")
    }

    // MARK: - Failure modes

    func testMissingTxtReturnsFailure() async {
        let candidate = RelayCandidate(
            txtURL: relay.appendingPathComponent("never-existed.txt"),
            audioURL: nil,
            relayFilename: "never-existed.txt",
            baseName: "never-existed"
        )

        let result = await filer.file(candidate, to: output, mode: .raw)

        guard case .failure = result.outcome else {
            return XCTFail("expected failure for an unreadable relay txt")
        }
    }

    func testAudioCopyFailureFilesTextOnlyAndReportsFailedAttachment() async throws {
        let txtURL = relay.appendingPathComponent(txtName)
        try "body".write(to: txtURL, atomically: true, encoding: .utf8)
        let missingAudio = relay.appendingPathComponent(m4aName) // never written
        let candidate = RelayCandidate(txtURL: txtURL, audioURL: missingAudio, relayFilename: txtName, baseName: baseName)

        let result = await filer.file(candidate, to: output, mode: .raw)

        XCTAssertTrue(result.isSuccess, "the note text still files when its audio can't be copied")
        XCTAssertEqual(result.failedAttachments, [missingAudio.path])
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent(txtName), encoding: .utf8), "body",
                       "no Attachments footer when nothing was copied")
        XCTAssertFalse(fm.fileExists(atPath: output.appendingPathComponent(baseName, isDirectory: true).path),
                       "the empty attachment folder is removed")
    }

    func testGarbageFilenameWithoutTimestampStillFiles() async throws {
        let name = "not a contract name.txt"
        let txtURL = relay.appendingPathComponent(name)
        try "content".write(to: txtURL, atomically: true, encoding: .utf8)
        let candidate = RelayCandidate(txtURL: txtURL, audioURL: nil, relayFilename: name, baseName: "not a contract name")

        let result = await filer.file(candidate, to: output, mode: .raw)

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent(name), encoding: .utf8), "content")
    }

    // MARK: - Orphan audio

    func testOrphanAudioFiledIntoSiblingFolder() async throws {
        let audioURL = relay.appendingPathComponent(m4aName)
        try Data([0x0A]).write(to: audioURL)
        // The common case: the note already filed text-only.
        try "note".write(to: output.appendingPathComponent(txtName), atomically: true, encoding: .utf8)

        let result = await filer.fileOrphanAudio(at: audioURL, to: output, preferredDirectory: nil)

        XCTAssertTrue(result.isSuccess)
        let expected = output.appendingPathComponent(baseName, isDirectory: true).appendingPathComponent(m4aName)
        XCTAssertTrue(fm.fileExists(atPath: expected.path),
                      "orphan audio lands in the sibling folder its note's footer would have pointed to")
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent(txtName), encoding: .utf8), "note",
                       "the filed note is never rewritten")
    }

    func testOrphanAudioCollisionWalksToNextDirectory() async throws {
        let audioURL = relay.appendingPathComponent(m4aName)
        try Data([0x0A]).write(to: audioURL)
        let existingDir = output.appendingPathComponent(baseName, isDirectory: true)
        try fm.createDirectory(at: existingDir, withIntermediateDirectories: true)
        try "occupied".write(to: existingDir.appendingPathComponent("something.jpg"), atomically: true, encoding: .utf8)

        let result = await filer.fileOrphanAudio(at: audioURL, to: output, preferredDirectory: nil)

        XCTAssertTrue(result.isSuccess)
        let walked = output.appendingPathComponent(baseName + "-1", isDirectory: true).appendingPathComponent(m4aName)
        XCTAssertTrue(fm.fileExists(atPath: walked.path))
    }

    func testOrphanAudioMissingSourceFails() async {
        let result = await filer.fileOrphanAudio(at: relay.appendingPathComponent("gone.m4a"), to: output, preferredDirectory: nil)
        guard case .failure = result.outcome else {
            return XCTFail("expected failure for a missing orphan source")
        }
        XCTAssertFalse(fm.fileExists(atPath: output.appendingPathComponent("gone", isDirectory: true).path),
                       "no empty directory left behind")
    }
}
