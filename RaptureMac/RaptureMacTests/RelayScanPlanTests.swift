import XCTest
@testable import Rapture

/// Pure planner tests: all pairing/grace/orphan decisions flow from an injected
/// directory snapshot, first-seen map, and clock. No filesystem involved.
final class RelayScanPlanTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let txt = "2026-07-06T15-14-42Z Grocery Ideas.txt"
    private let m4a = "2026-07-06T15-14-42Z Grocery Ideas.m4a"

    private func seenAgo(_ interval: TimeInterval, _ names: String...) -> [String: Date] {
        Dictionary(uniqueKeysWithValues: names.map { ($0, now.addingTimeInterval(-interval)) })
    }

    // MARK: - Basic classification

    func testEmptyListingYieldsNothing() {
        let plan = RelayWatcher.plan(entries: [], firstSeen: [:], now: now)
        XCTAssertTrue(plan.readyTxt.isEmpty)
        XCTAssertTrue(plan.orphanAudio.isEmpty)
        XCTAssertTrue(plan.placeholdersToNudge.isEmpty)
        XCTAssertTrue(plan.newFirstSeen.isEmpty)
    }

    func testIgnoresDSStoreHiddenAndUnknownExtensions() {
        let plan = RelayWatcher.plan(
            entries: [".DS_Store", ".hidden-thing", "stray.pdf", "README"],
            firstSeen: [:],
            now: now
        )
        XCTAssertTrue(plan.readyTxt.isEmpty)
        XCTAssertTrue(plan.orphanAudio.isEmpty)
        XCTAssertTrue(plan.placeholdersToNudge.isEmpty)
        XCTAssertTrue(plan.newFirstSeen.isEmpty, "ignored files must not be tracked")
    }

    // MARK: - Pairing grace

    func testFreshTxtWithoutAudioWaitsDuringGrace() {
        let plan = RelayWatcher.plan(entries: [txt], firstSeen: [:], now: now)
        XCTAssertTrue(plan.readyTxt.isEmpty, "a fresh txt must wait out the pairing grace")
        XCTAssertEqual(plan.newFirstSeen[txt], now, "first sighting must be recorded")
    }

    func testTxtWithoutAudioReadyAfterGrace() {
        let plan = RelayWatcher.plan(
            entries: [txt],
            firstSeen: seenAgo(RelayWatcher.pairingGrace, txt),
            now: now
        )
        XCTAssertEqual(plan.readyTxt, [RelayWatcher.ReadyTxt(name: txt, audioName: nil)])
    }

    func testTxtWithVisibleAudioReadyImmediately() {
        let plan = RelayWatcher.plan(entries: [txt, m4a], firstSeen: [:], now: now)
        XCTAssertEqual(plan.readyTxt, [RelayWatcher.ReadyTxt(name: txt, audioName: m4a)],
                       "a downloaded pair needs no grace period")
    }

    // MARK: - Placeholders

    func testTxtWithAudioPlaceholderWaitsAndNudges() {
        let placeholder = ".\(m4a).icloud"
        let plan = RelayWatcher.plan(
            entries: [txt, placeholder],
            firstSeen: seenAgo(RelayWatcher.pairingGrace + 5, txt, m4a),
            now: now
        )
        XCTAssertTrue(plan.readyTxt.isEmpty,
                      "a visible audio placeholder extends the wait past the normal grace")
        XCTAssertEqual(plan.placeholdersToNudge, [m4a])
    }

    func testTxtWithAudioPlaceholderFilesTextOnlyAfterCap() {
        let placeholder = ".\(m4a).icloud"
        let plan = RelayWatcher.plan(
            entries: [txt, placeholder],
            firstSeen: seenAgo(RelayWatcher.audioPlaceholderWaitCap, txt, m4a),
            now: now
        )
        XCTAssertEqual(plan.readyTxt, [RelayWatcher.ReadyTxt(name: txt, audioName: nil)],
                       "past the cap the note files text-only; orphan recovery gets the audio later")
    }

    func testTxtPlaceholderNudgedNotReady() {
        let placeholder = ".\(txt).icloud"
        let plan = RelayWatcher.plan(entries: [placeholder], firstSeen: [:], now: now)
        XCTAssertTrue(plan.readyTxt.isEmpty)
        XCTAssertEqual(plan.placeholdersToNudge, [txt])
        XCTAssertEqual(plan.newFirstSeen[txt], now)
    }

    // MARK: - Orphan audio

    func testOrphanAudioFlaggedAfterOrphanGrace() {
        let plan = RelayWatcher.plan(
            entries: [m4a],
            firstSeen: seenAgo(RelayWatcher.orphanAudioGrace, m4a),
            now: now
        )
        XCTAssertEqual(plan.orphanAudio, [m4a])
    }

    func testFreshAudioNotOrphanedYet() {
        let plan = RelayWatcher.plan(
            entries: [m4a],
            firstSeen: seenAgo(RelayWatcher.orphanAudioGrace - 1, m4a),
            now: now
        )
        XCTAssertTrue(plan.orphanAudio.isEmpty)
    }

    func testOrphanAudioSuppressedWhileTxtPlaceholderPresent() {
        let placeholder = ".\(txt).icloud"
        let plan = RelayWatcher.plan(
            entries: [m4a, placeholder],
            firstSeen: seenAgo(RelayWatcher.orphanAudioGrace, m4a, txt),
            now: now
        )
        XCTAssertTrue(plan.orphanAudio.isEmpty,
                      "audio is not orphaned while its txt is still downloading")
    }

    // MARK: - First-seen tracking

    func testFirstSeenPrunedWhenFileDisappears() {
        let plan = RelayWatcher.plan(
            entries: [txt],
            firstSeen: seenAgo(50, txt, "gone.txt"),
            now: now
        )
        XCTAssertNil(plan.newFirstSeen["gone.txt"])
        XCTAssertNotNil(plan.newFirstSeen[txt])
    }

    func testFirstSeenPreservedAcrossScans() {
        let earlier = now.addingTimeInterval(-3)
        let plan = RelayWatcher.plan(entries: [txt], firstSeen: [txt: earlier], now: now)
        XCTAssertEqual(plan.newFirstSeen[txt], earlier, "re-sighting must not reset the clock")
    }

    // MARK: - Name helpers

    func testPlaceholderTargetParsing() {
        XCTAssertEqual(RelayWatcher.placeholderTarget(".\(txt).icloud"), txt)
        XCTAssertNil(RelayWatcher.placeholderTarget(".DS_Store"))
        XCTAssertNil(RelayWatcher.placeholderTarget(txt))
        XCTAssertNil(RelayWatcher.placeholderTarget(".icloud"), "an empty target is not a placeholder")
    }

    func testPairedNameMapping() {
        XCTAssertEqual(RelayWatcher.pairedAudioName(forTxt: txt), m4a)
        XCTAssertEqual(RelayWatcher.pairedTxtName(forAudio: m4a), txt)
    }

    func testParseRelayTimestampValidInvalidAndShortNames() {
        let date = RelayWatcher.parseRelayTimestamp(txt)
        XCTAssertNotNil(date)
        if let date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            XCTAssertEqual(parts.year, 2026)
            XCTAssertEqual(parts.month, 7)
            XCTAssertEqual(parts.day, 6)
            XCTAssertEqual(parts.hour, 15)
            XCTAssertEqual(parts.minute, 14)
            XCTAssertEqual(parts.second, 42)
        }
        XCTAssertNil(RelayWatcher.parseRelayTimestamp("grocery list.txt"))
        XCTAssertNil(RelayWatcher.parseRelayTimestamp("short.txt"))
    }
}
