import XCTest
@testable import Rapture

final class PrerequisitesTests: XCTestCase {

    // MARK: - TCC URL map

    func testKnownTCCNamesResolveToExpectedURLs() {
        XCTAssertEqual(
            Prerequisites.tccURL(for: "Reminders").absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
        )
        XCTAssertEqual(
            Prerequisites.tccURL(for: "Calendar").absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendar"
        )
        XCTAssertEqual(
            Prerequisites.tccURL(for: "Contacts").absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
        )
        XCTAssertEqual(
            Prerequisites.tccURL(for: "Accessibility").absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
        XCTAssertEqual(
            Prerequisites.tccURL(for: "FullDiskAccess").absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        )
        XCTAssertEqual(
            Prerequisites.tccURL(for: "Automation").absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        )
    }

    func testUnknownTCCNameFallsBackToPrivacyRoot() {
        let url = Prerequisites.tccURL(for: "Telephony")
        XCTAssertEqual(url.absoluteString, "x-apple.systempreferences:com.apple.preference.security?Privacy")
    }

    // MARK: - Install commands

    func testKnownCLIInstallCommandsAreCanonical() {
        XCTAssertEqual(Prerequisites.installCommands["jq"], "brew install jq")
        XCTAssertEqual(Prerequisites.installCommands["fswatch"], "brew install fswatch")
        XCTAssertEqual(Prerequisites.installCommands["claude"], "brew install --cask claude-code")
    }

    func testUnknownCLIFallsBackToGenericBrewInstallCommand() {
        let report = Prerequisites.detect(
            Requires(cli: ["totally-unknown-cli"], brew: [], tcc: []),
            exists: { _ in false }
        )
        let item = report.missingItems.first
        XCTAssertEqual(item?.installCommand, "brew install totally-unknown-cli")
    }

    // MARK: - Detection via injected lookup

    func testEmptyRequiresReturnsEmptyReport() {
        let report = Prerequisites.detect(Requires.empty, exists: { _ in true })
        XCTAssertTrue(report.missingCLIs.isEmpty)
        XCTAssertTrue(report.missingBrew.isEmpty)
        XCTAssertTrue(report.tccDeepLinks.isEmpty)
        XCTAssertTrue(report.allCLIsPresent)
    }

    func testAllCLIsPresentMarksReportAllPresent() {
        let report = Prerequisites.detect(
            Requires(cli: ["claude", "jq", "fswatch"], brew: [], tcc: []),
            exists: { _ in true }
        )
        XCTAssertTrue(report.missingCLIs.isEmpty)
        XCTAssertTrue(report.allCLIsPresent)
        XCTAssertTrue(report.missingItems.isEmpty)
    }

    func testMissingCLIIsReported() {
        let report = Prerequisites.detect(
            Requires(cli: ["claude", "jq", "fswatch"], brew: [], tcc: []),
            exists: { name in name != "fswatch" }
        )
        XCTAssertEqual(report.missingCLIs, ["fswatch"])
        XCTAssertFalse(report.allCLIsPresent)
        XCTAssertEqual(report.missingItems.map(\.name), ["fswatch"])
        XCTAssertEqual(report.missingItems.first?.installCommand, "brew install fswatch")
    }

    func testMissingBrewPackageIsReportedSeparatelyFromCLI() {
        let report = Prerequisites.detect(
            Requires(cli: [], brew: ["ripgrep"], tcc: []),
            exists: { _ in false }
        )
        XCTAssertTrue(report.missingCLIs.isEmpty)
        XCTAssertEqual(report.missingBrew, ["ripgrep"])
    }

    func testMissingItemsCombinesCLIsAndBrew() {
        let report = Prerequisites.detect(
            Requires(cli: ["a"], brew: ["b"], tcc: []),
            exists: { _ in false }
        )
        XCTAssertEqual(report.missingItems.map(\.name), ["a", "b"])
    }

    // MARK: - TCC entries flow through

    func testRequiresWithTCCProducesTCCEntries() {
        let report = Prerequisites.detect(
            Requires(cli: [], brew: [], tcc: ["Reminders", "Calendar"]),
            exists: { _ in true }
        )
        XCTAssertEqual(report.tccDeepLinks.map(\.name), ["Reminders", "Calendar"])
        XCTAssertEqual(
            report.tccDeepLinks.first?.url.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
        )
    }

    // MARK: - Real filesystem lookup (sanity check)

    func testWhichExitsTrueForBin() {
        // /bin always has at least `sh` on macOS.
        XCTAssertTrue(Prerequisites.whichExits("sh"))
    }

    func testWhichExitsFalseForNonsenseCommand() {
        XCTAssertFalse(Prerequisites.whichExits("this-binary-does-not-exist-anywhere-1234"))
    }
}
