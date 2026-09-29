import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(UpdaterController.self) private var updater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let status = MenuBarStatus.line(
            permission: appState.permissionState,
            automation: appState.automationPermissionState,
            paused: appState.settings.settings.paused,
            destinationOffline: appState.destinationOffline,
            queuedCount: appState.queuedCaptureCount,
            lastError: appState.lastError,
            repliesOff: appState.settings.settings.replyMode == .off
        )

        VStack(alignment: .leading, spacing: 10) {
            statusBlock(status: status)
            triageIntroNotice
            Divider()
            actions(status: status)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .frame(width: 300, alignment: .leading)
    }

    @ViewBuilder
    private func statusBlock(status: MenuBarStatus.Line) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(status.primary)
                .font(.headline)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            secondaryLine
                .font(.caption)
                .foregroundStyle(.secondary)

            if case .triaging(let done, let total) = appState.triageStatus {
                Text("Triaging notes… \(done) of \(total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if status.kind == .error, let newest = appState.newestError {
                HStack(spacing: 6) {
                    Text(errorCaption(newest))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss") { appState.dismissAllErrors() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            if !appState.destinationOffline, appState.queuedCaptureCount > 0 {
                Text("\(appState.queuedCaptureCount) \(appState.queuedCaptureCount == 1 ? "capture is" : "captures are") queued behind one that can't file yet. They file in order once it does.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let since = appState.relayWaitingSince,
               Date().timeIntervalSince(since) >= Self.relayStuckWarning {
                Text("A note from your iPhone has waited \(Int(Date().timeIntervalSince(since) / 60)) min for iCloud. Open the Rapture app on your iPhone while it's on Wi-Fi.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if status.kind == .destinationOffline {
                Text("Captures keep queueing and file automatically when the drive reconnects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Backup-health warning: an additional caption (capture still works —
            // it's the destination's backup that's stale), gated on the opt-in
            // toggle. No new MenuBarStatus.Kind.
            if let backupWarning = BackupHealthPresentation.menuWarning(
                appState.backupHealth,
                enabled: appState.settings.settings.vaultBackupWarningsEnabled
            ) {
                Text(backupWarning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One-time "what changed" notice for updaters: captures now file as Markdown.
    /// Dismissal persists via `triageIntroShown`, so it never reappears.
    @ViewBuilder
    private var triageIntroNotice: some View {
        if !appState.state.state.triageIntroShown {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New: captures now file as Markdown notes")
                        .font(.caption)
                    Text("Sorted into folders like Notes/, Links/ and Meetings/. If you used your own scripts on the old .txt files, update them, or switch back in Settings → Triage.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    appState.state.update { $0.triageIntroShown = true }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.top, 2)
        }
    }

    private var secondaryLine: Text {
        let now = Date()
        let count = appState.state.state.displayedTodayCount(at: now)
        let countText = "Today: \(count) \(count == 1 ? "note" : "notes")"

        guard let last = appState.state.state.lastCaptureAt else {
            return Text(countText)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let relative = formatter.localizedString(for: last, relativeTo: now)
        return Text("\(countText) · Last \(relative)")
    }

    @ViewBuilder
    private func actions(status: MenuBarStatus.Line) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch status.kind {
            case .fullDiskAccessNeeded, .automationNeeded:
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "permissions")
                } label: {
                    rowLabel("Show permissions help…", symbol: "questionmark.circle")
                }
                .buttonStyle(.plain)

            default:
                Button {
                    appState.settings.update { $0.paused.toggle() }
                } label: {
                    rowLabel(
                        appState.settings.settings.paused ? "Resume Capture" : "Pause Capture",
                        symbol: appState.settings.settings.paused ? "play.fill" : "pause.fill"
                    )
                }
                .buttonStyle(.plain)
                .disabled(appState.permissionState != .ok)
            }

            Button(action: openOutputFolder) {
                rowLabel("Open Notes Folder", symbol: "folder")
            }
            .buttonStyle(.plain)
            .disabled(appState.settings.settings.outputFolder == nil)

            if let last = appState.activity.lastNote, let path = last.path {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    rowLabel("Show Last Note", symbol: "doc.text.magnifyingglass")
                }
                .buttonStyle(.plain)
                .help(last.summary)
            }

            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "activity")
            } label: {
                rowLabel("Activity…", symbol: "clock.arrow.circlepath")
            }
            .buttonStyle(.plain)

            Button {
                openSettings()
            } label: {
                rowLabel("Settings…", symbol: "gearshape")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)

            Button(action: { updater.checkForUpdates() }) {
                rowLabel("Check for Updates…", symbol: "arrow.down.circle")
            }
            .buttonStyle(.plain)
            .disabled(!updater.canCheckForUpdates)

            Divider()
                .padding(.vertical, 2)

            Button(action: { NSApp.terminate(nil) }) {
                rowLabel("Quit Rapture", symbol: "power")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    @ViewBuilder
    private func rowLabel(_ text: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(text)
            Spacer()
        }
        .contentShape(Rectangle())
    }

    /// An iPhone note waiting this long for iCloud gets a menu warning.
    static let relayStuckWarning: TimeInterval = 10 * 60

    private func errorCaption(_ error: ErrorRecord) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let when = formatter.localizedString(for: error.at, relativeTo: Date())
        let others = appState.errors.count - 1
        return others > 0 ? "\(when) · \(others) more in Activity" : when
    }

    /// Settings always opens on General from the menu, rather than on
    /// whichever tab was last left open.
    private func openSettings() {
        appState.settingsTab = .general
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
    }

    private func openOutputFolder() {
        guard let folder = appState.settings.settings.outputFolder else { return }
        NSWorkspace.shared.open(folder)
    }
}
