import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let status = MenuBarStatus.line(
            permission: appState.permissionState,
            automation: appState.automationPermissionState,
            paused: appState.settings.settings.paused,
            lastError: appState.lastError
        )

        VStack(alignment: .leading, spacing: 10) {
            statusBlock(status: status)
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

            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "settings")
            } label: {
                rowLabel("Settings…", symbol: "gearshape")
            }
            .buttonStyle(.plain)

            Divider()
                .padding(.vertical, 2)

            Button(action: { NSApp.terminate(nil) }) {
                rowLabel("Quit Rapture", symbol: "power")
            }
            .buttonStyle(.plain)
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

    private func openOutputFolder() {
        guard let folder = appState.settings.settings.outputFolder else { return }
        NSWorkspace.shared.open(folder)
    }
}
