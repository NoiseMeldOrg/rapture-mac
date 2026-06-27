import Foundation

extension ProcessInfo {
    /// True when this process is hosting an XCTest run.
    ///
    /// The unit-test bundle is hosted *inside* `Rapture.app` (see `TEST_HOST` in the
    /// project), so the app's `@main` startup runs during `xcodebuild test`. Anything that
    /// startup does — opening `chat.db` (which triggers a Full Disk Access TCC prompt),
    /// spawning a login shell, scheduling Sparkle, polling the watcher — only adds
    /// nondeterminism to the headless test host and, in the chat.db case, can disrupt the
    /// host badly enough that xcodebuild reports "Restarting after unexpected exit."
    /// Gating that machinery on this flag keeps the test host inert.
    ///
    /// Detected via XCTest's well-known environment variable, which is present in the test
    /// host but never in a normally-launched app.
    var isRunningXCTests: Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }
}
