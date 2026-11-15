import XCTest
@testable import Rapture

/// A Debug build must not share the installed app's bundle id.
///
/// macOS keys privacy grants (Full Disk Access, Automation, Documents) on the
/// bundle id plus the signature. A Debug build is ad-hoc signed, so under the
/// shared id `noisemeld.RaptureMac` its first read of `chat.db` made `tccd`
/// replace the installed app's Full Disk Access grant with a denial
/// (2026-11-15). With its own id the Debug build gets its own grants and
/// cannot change the installed app's.
///
/// The test bundle is hosted in `Rapture.app`, so `Bundle.main` here is the
/// app under test.
final class DebugBuildIdentityTests: XCTestCase {
    func testDebugBuildHasItsOwnBundleIdentifier() {
        #if DEBUG
        XCTAssertEqual(Bundle.main.bundleIdentifier, "noisemeld.RaptureMac.debug")
        #else
        XCTAssertEqual(Bundle.main.bundleIdentifier, "noisemeld.RaptureMac")
        #endif
    }

    /// Two apps named "Rapture" in a privacy list or a permission prompt
    /// cannot be told apart. The Debug build names itself.
    func testDebugBuildNamesItselfInPermissionPrompts() {
        let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        #if DEBUG
        XCTAssertEqual(displayName, "Rapture (Debug)")
        #else
        XCTAssertEqual(displayName, "Rapture")
        #endif
    }
}
