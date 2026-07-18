import XCTest
@testable import Rapture

/// The toggle proof and the plain-language wording, tested without a SwiftUI host.
/// Key invariant: the Settings status line is shown regardless of the toggle,
/// while the menu-bar warning is gated on it.
final class BackupHealthPresentationTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func atRisk(daysAgo: Double = 2) -> BackupHealth {
        .atRisk(since: now.addingTimeInterval(-daysAgo * 86_400), uncommitted: 27, unpushed: 0)
    }

    // MARK: - Toggle gates the menu warning only

    func testMenuWarningHiddenWhenToggleOff() {
        XCTAssertNil(BackupHealthPresentation.menuWarning(atRisk(), enabled: false, now: now))
    }

    func testMenuWarningShownWhenToggleOnAndAtRisk() {
        let warning = BackupHealthPresentation.menuWarning(atRisk(), enabled: true, now: now)
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning!.contains("not backed up"))
        XCTAssertTrue(warning!.contains("2 days"))
    }

    func testMenuWarningHiddenWhenHealthyEvenWithToggleOn() {
        XCTAssertNil(BackupHealthPresentation.menuWarning(.backedUp(lastCommit: now, pendingChanges: 0), enabled: true, now: now))
    }

    func testSettingsLineShownForAtRiskRegardlessOfToggle() {
        // The Settings line ignores the toggle entirely — same input, always shown,
        // as a warning. This is what keeps the info one glance away with warnings off.
        let line = BackupHealthPresentation.settingsLine(atRisk(), now: now)
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.isWarning)
        XCTAssertTrue(line!.text.contains("27 uncommitted changes"))
        XCTAssertTrue(line!.text.contains("2 days"))
    }

    // MARK: - Settings line per state

    func testSettingsLineHiddenBeforeFirstCheck() {
        XCTAssertNil(BackupHealthPresentation.settingsLine(.unknown, now: now))
    }

    func testSettingsLineForNotARepoIsNeutral() {
        let line = BackupHealthPresentation.settingsLine(.notARepo, now: now)
        XCTAssertEqual(line?.isWarning, false)
        XCTAssertTrue(line?.text.contains("isn't a git repository") ?? false)
    }

    func testSettingsLineForCannotCheckIsNeutral() {
        let line = BackupHealthPresentation.settingsLine(.cannotCheck, now: now)
        XCTAssertEqual(line?.isWarning, false)
        XCTAssertTrue(line?.text.lowercased().contains("drive isn't connected") ?? false)
    }

    func testSettingsLineForBackedUpIsHealthy() {
        let line = BackupHealthPresentation.settingsLine(.backedUp(lastCommit: now.addingTimeInterval(-7_200), pendingChanges: 0), now: now)
        XCTAssertEqual(line?.isWarning, false)
        XCTAssertEqual(line?.systemImage, "checkmark.circle")
        XCTAssertTrue(line?.text.contains("2h ago") ?? false)
    }

    func testSettingsLineForBackedUpNotesPendingChanges() {
        let line = BackupHealthPresentation.settingsLine(.backedUp(lastCommit: now, pendingChanges: 3), now: now)
        XCTAssertTrue(line?.text.contains("3 changes not yet backed up") ?? false)
    }

    // MARK: - Phrasing helpers (deterministic)

    func testDurationPhrase() {
        XCTAssertEqual(BackupHealthPresentation.durationPhrase(since: now.addingTimeInterval(-90_000), now: now), "1 day")
        XCTAssertEqual(BackupHealthPresentation.durationPhrase(since: now.addingTimeInterval(-3 * 86_400), now: now), "3 days")
        XCTAssertEqual(BackupHealthPresentation.durationPhrase(since: now.addingTimeInterval(-7_200), now: now), "2 hours")
    }

    func testAgoPhrase() {
        XCTAssertEqual(BackupHealthPresentation.agoPhrase(now.addingTimeInterval(-30), now: now), "just now")
        XCTAssertEqual(BackupHealthPresentation.agoPhrase(now.addingTimeInterval(-300), now: now), "5m ago")
        XCTAssertEqual(BackupHealthPresentation.agoPhrase(now.addingTimeInterval(-7_200), now: now), "2h ago")
        XCTAssertEqual(BackupHealthPresentation.agoPhrase(now.addingTimeInterval(-3 * 86_400), now: now), "3d ago")
    }
}
