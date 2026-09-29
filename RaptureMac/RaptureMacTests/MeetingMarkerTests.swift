import XCTest
@testable import Rapture

/// The iOS meeting marker parse, the meeting ledger's pure helpers, and the
/// meeting filer's pure helpers. Table-style, no filesystem except the
/// frontmatter probe.
final class MeetingMarkerTests: XCTestCase {

    private let uuid = "0C6B2A4E-9F1D-4E51-A7C3-2B8D5E9F1A10"

    // MARK: - Marker parse

    func testTranscriptMarkerIsStrippedAndBodyStartsAtTitle() throws {
        let text = "<!-- rapture-meeting id=\(uuid) part=transcript -->\n# Meeting, Sep 29, 2:30 PM\n\nDana · 0:00\nOkay.\n"
        let parsed = try XCTUnwrap(MeetingMarker.parse(text))
        XCTAssertEqual(parsed.header, MeetingMarker.Header(meetingId: uuid, part: .transcript))
        XCTAssertEqual(parsed.body, "# Meeting, Sep 29, 2:30 PM\n\nDana · 0:00\nOkay.\n")
        XCTAssertTrue(TriageClassifier.stripLeadingHeading(parsed.body).hasPrefix("\n"),
                      "after the strip, the # title line is first again")
    }

    func testSummaryMarkerKeysInAnyOrderUnknownKeysIgnored() throws {
        let text = "<!-- rapture-meeting part=summary v=2 id=\(uuid) -->\n# Budget planning\n"
        let parsed = try XCTUnwrap(MeetingMarker.parse(text))
        XCTAssertEqual(parsed.header.part, .summary)
        XCTAssertEqual(parsed.header.meetingId, uuid)
    }

    func testLowercaseUUIDIsCanonicalized() throws {
        let text = "<!-- rapture-meeting id=\(uuid.lowercased()) part=summary -->\nbody"
        XCTAssertEqual(MeetingMarker.parse(text)?.header.meetingId, uuid)
    }

    func testCRLFAndBOMAreTolerated() throws {
        let text = "\u{FEFF}<!-- rapture-meeting id=\(uuid) part=transcript -->\r\n# T\r\nx"
        let parsed = try XCTUnwrap(MeetingMarker.parse(text))
        XCTAssertEqual(parsed.body, "# T\r\nx")
    }

    func testNonMarkerTextIsNotAMeeting() {
        let rejected = [
            "# Grocery ideas\n\nMilk",
            "",
            "<!-- a normal comment -->\nbody",
            "<!-- rapture-meeting part=summary -->\nno id",
            "<!-- rapture-meeting id=\(uuid) -->\nno part",
            "<!-- rapture-meeting id=\(uuid) part=agenda -->\nunknown part",
            "<!-- rapture-meeting id=a:b part=summary -->\nhostile id",
            "<!-- rapture-meeting id=\(uuid) part=summary\nunterminated",
            "# Title\n<!-- rapture-meeting id=\(uuid) part=summary -->\nmarker not first",
        ]
        for text in rejected {
            XCTAssertNil(MeetingMarker.parse(text), "should not parse: \(text.debugDescription)")
        }
    }

    func testHeadingTitleIsFilenameSafe() {
        XCTAssertEqual(MeetingMarker.headingTitle(of: "# Meeting, Sep 29, 2:30 PM\n\nx"), "Meeting, Sep 29, 2 30 PM")
        XCTAssertNil(MeetingMarker.headingTitle(of: "No heading"))
    }

    func testPeekReadsOnlyTheHead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("peek-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let big = String(repeating: "Alex · 1:12\nwords words words\n\n", count: 3_000)
        try ("<!-- rapture-meeting id=\(uuid) part=transcript -->\n# M\n\n" + big).write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(MeetingMarker.peek(fileAt: url), MeetingMarker.Header(meetingId: uuid, part: .transcript))
    }

    // MARK: - Ledger helpers

    private func entry(_ id: String, at date: Date, hashes: [String] = []) -> MeetingEntry {
        MeetingEntry(meetingId: id, noteRelativePath: "Meetings/x.md", part: .transcript,
                     relayFilenames: [], appliedSummaryHashes: hashes, updatedAt: date)
    }

    func testUpsertReplacesSameIdAndMovesItLast() {
        let now = Date()
        let start = [entry("A", at: now), entry("B", at: now)]
        var updated = entry("A", at: now)
        updated.noteRelativePath = "Meetings/renamed.md"
        let result = MeetingLedger.upserting(updated, into: start, now: now)
        XCTAssertEqual(result.map(\.meetingId), ["B", "A"])
        XCTAssertEqual(result.last?.noteRelativePath, "Meetings/renamed.md")
    }

    func testUpsertCapsSummaryHashesAndDropsExpiredEntries() {
        let now = Date()
        let stale = entry("OLD", at: now.addingTimeInterval(-MeetingLedger.ttl - 1))
        let hashes = (0..<30).map { "h\($0)" }
        let result = MeetingLedger.upserting(entry("A", at: now, hashes: hashes), into: [stale], now: now)
        XCTAssertEqual(result.map(\.meetingId), ["A"])
        XCTAssertEqual(result[0].appliedSummaryHashes.count, MeetingLedger.summaryHashCapacity)
        XCTAssertEqual(result[0].appliedSummaryHashes.last, "h29", "newest hashes are kept")
    }

    // MARK: - Filer helpers

    func testBaseMatchesAllowsCollisionSuffixOnly() {
        XCTAssertTrue(MeetingFiler.baseMatches("2026-09-29 Budget", base: "2026-09-29 Budget"))
        XCTAssertTrue(MeetingFiler.baseMatches("2026-09-29 Budget-2", base: "2026-09-29 Budget"))
        XCTAssertFalse(MeetingFiler.baseMatches("2026-09-29 Budget-x", base: "2026-09-29 Budget"))
        XCTAssertFalse(MeetingFiler.baseMatches("2026-09-29 Budget planning", base: "2026-09-29 Budget"))
    }

    func testReplacingMarkdownFooterRebuildsItFromFiles() {
        let note = "---\ntype: meeting\n---\n\n# T\nbody\n\nAttachments:\n- [a.m4a](<Old/a.m4a>)\n"
        let updated = NoteFooter.replacing(in: note, isMarkdown: true, folder: "New", files: ["a.m4a", "b.m4a"])
        XCTAssertEqual(updated, "---\ntype: meeting\n---\n\n# T\nbody\n\nAttachments:\n- [a.m4a](<New/a.m4a>)\n- [b.m4a](<New/b.m4a>)\n")
        let added = NoteFooter.replacing(in: "---\n---\n\nbody\n", isMarkdown: true, folder: "F", files: ["a.m4a"])
        XCTAssertEqual(added, "---\n---\n\nbody\n\nAttachments:\n- [a.m4a](<F/a.m4a>)\n")
    }

    func testReplacingPlainFooter() {
        let updated = NoteFooter.replacing(in: "body", isMarkdown: false, folder: "F", files: ["a.m4a"])
        XCTAssertEqual(updated, "body\n\nAttachments:\n- F/a.m4a\n")
    }

    func testComposeCarriesMeetingId() {
        let note = CaptureContract.Note(
            capturedAt: Date(timeIntervalSince1970: 0), source: .raptureIOS, type: .meeting,
            rawMedia: nil, body: "# M", rawBody: nil, meetingId: uuid)
        XCTAssertEqual(
            CaptureContract.compose(note),
            "---\ncaptured: 1970-01-01T00:00:00Z\nsource: rapture-ios\ntype: meeting\nmeeting_id: \(uuid)\n---\n\n# M\n")
        XCTAssertEqual(CaptureType.meeting.subfolder, "Meetings")
    }
}
