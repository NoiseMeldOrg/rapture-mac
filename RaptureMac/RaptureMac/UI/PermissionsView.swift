import SwiftUI
import AppKit

/// Permission help. Shows the Full Disk Access steps when that is what's
/// missing, otherwise the Automation (Messages replies) steps: the menu's
/// "Show permissions help…" row opens this for either.
struct PermissionsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismissWindow) private var dismissWindow

    private static let fdaSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    private static let automationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    /// How long after opening System Settings before offering the relaunch
    /// button: enough to flip the switch.
    private static let reopenHintDelay: TimeInterval = 8

    @State private var openedSettingsAt: Date?
    @State private var showReopen = false

    var body: some View {
        Group {
            if appState.permissionState == .fullDiskAccessRequired {
                fullDiskAccess
            } else {
                automation
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 340)
        .onChange(of: appState.permissionState) { _, newValue in
            if newValue == .ok, appState.automationPermissionState != .required {
                dismissWindow(id: "permissions")
            }
        }
    }

    // MARK: - Full Disk Access

    private var fullDiskAccess: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Rapture needs Full Disk Access")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Rapture reads your Messages so the notes you text yourself can be saved on this Mac. macOS only allows that with Full Disk Access.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("Click Open System Settings below.", systemImage: "1.circle")
                Label("Find Rapture in the list and turn it on.", systemImage: "2.circle")
                Label("When macOS asks, click Quit & Reopen. If it doesn't ask, click Reopen Rapture here.", systemImage: "3.circle")
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            Text("Not in the list? Click the **+** button in System Settings and add Rapture from your Applications folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            HStack {
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if showReopen {
                    Button("Reopen Rapture") {
                        AppRelauncher.relaunch()
                    }
                    .help("Rapture must restart to use a permission you just turned on.")
                }

                Button("Open System Settings") {
                    NSWorkspace.shared.open(Self.fdaSettingsURL)
                    openedSettingsAt = Date()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .task(id: openedSettingsAt) {
            guard openedSettingsAt != nil else { return }
            try? await Task.sleep(for: .seconds(Self.reopenHintDelay))
            showReopen = true
        }
    }

    // MARK: - Automation

    private var automation: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Let Rapture reply in Messages")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Your notes are still being saved. Only the \"✅ Saved\" replies are blocked, because macOS turned off Rapture's permission to control Messages.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("Click Open System Settings below.", systemImage: "1.circle")
                Label("Under Rapture, turn on Messages.", systemImage: "2.circle")
                Label("The next reply goes through and this warning clears.", systemImage: "3.circle")
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            Text("Don't want replies? Choose Never reply in Settings → General, and this warning goes away.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            HStack {
                Button("Never Reply") {
                    appState.settings.update { $0.replyMode = .off }
                    appState.automationPermissionState = .unknown
                    appState.clearError(source: .reply)
                    dismissWindow(id: "permissions")
                }
                Spacer()
                Button("Open System Settings") {
                    NSWorkspace.shared.open(Self.automationSettingsURL)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
