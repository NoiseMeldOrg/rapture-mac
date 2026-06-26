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

    /// True when a manual check is allowed (false while one is already running, or when
    /// the updater is inert because no real EdDSA key is configured — see below).
    private(set) var canCheckForUpdates = false

    /// Placeholder written by `Scripts/set_sparkle_info.sh` until a maintainer generates the
    /// real key. Sparkle treats an invalid/missing `SUPublicEDKey` as a **fatal** error the
    /// moment the updater starts, which would crash the app for any build made before the key
    /// is set (CI, a fresh clone). So we only start the updater once a real key is embedded;
    /// until then auto-update stays inert (you couldn't verify an update without the key anyway).
    private static let keyPlaceholder = "REPLACE_WITH_SPARKLE_EDDSA_PUBLIC_KEY"

    /// Whether a usable EdDSA public key is baked into this build.
    let isConfigured: Bool

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        isConfigured = !key.isEmpty && key != Self.keyPlaceholder

        // startingUpdater begins Sparkle's scheduled checks immediately; they only actually
        // fire if the user's automatic-check preference is on (default on via
        // SUEnableAutomaticChecks, toggleable in Settings → About).
        controller = SPUStandardUpdaterController(
            startingUpdater: isConfigured,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        guard isConfigured else { return }
        cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
    }

    /// Show the standard "Checking for updates…" flow (and the update prompt if one exists).
    func checkForUpdates() {
        guard isConfigured else { return }
        controller.updater.checkForUpdates()
    }

    /// Whether Sparkle checks for updates on its own schedule. Persisted by Sparkle.
    var automaticallyChecksForUpdates: Bool {
        get { isConfigured ? controller.updater.automaticallyChecksForUpdates : false }
        set { if isConfigured { controller.updater.automaticallyChecksForUpdates = newValue } }
    }

    /// When Sparkle last checked the appcast, for display in the About tab.
    var lastUpdateCheckDate: Date? {
        isConfigured ? controller.updater.lastUpdateCheckDate : nil
    }
}
