import Combine
import Foundation
import Sparkle

/// Thin wrapper around Sparkle's standard updater so SwiftUI can drive the menu's
/// "Check for Updates…" item and the About tab's auto-update toggle.
///
/// `SPUStandardUpdaterController` owns the whole Sparkle lifecycle — scheduled background
/// checks (gated by the user's `automaticallyChecksForUpdates` preference, which Sparkle
/// persists), download, and the standard update UI. This type just surfaces the few bits
/// the UI needs and mirrors `canCheckForUpdates` so the menu item can disable itself while
/// a check is in flight.
@Observable
@MainActor
final class UpdaterController {
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var cancellable: AnyCancellable?

    /// True when a manual check is allowed (false while one is already running).
    private(set) var canCheckForUpdates = false

    init() {
        // startingUpdater: true begins Sparkle's scheduled checks immediately; they only
        // actually fire if the user's automatic-check preference is on (default on, set via
        // SUEnableAutomaticChecks in Info.plist and toggleable in Settings → About).
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
    }

    /// Show the standard "Checking for updates…" flow (and the update prompt if one exists).
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// Whether Sparkle checks for updates on its own schedule. Persisted by Sparkle.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// When Sparkle last checked the appcast, for display in the About tab.
    var lastUpdateCheckDate: Date? {
        controller.updater.lastUpdateCheckDate
    }
}
