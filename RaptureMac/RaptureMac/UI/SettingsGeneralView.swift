import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsGeneralView: View {
    @Environment(AppState.self) private var appState

    @State private var launchAtLoginError: String?
    @State private var folderDropTargeted = false

    var body: some View {
        Form {
            if AppSupportDirectory.isDebugContainer {
                debugIsolationSection
            }
            outputFolderSection
            launchAtLoginSection
            replyModeSection
            smsSection
            relaySection
        }
        .formStyle(.grouped)
    }

    // MARK: - Debug isolation marker

    /// Only compiled into DEBUG builds. Makes the isolated container/default explicit so a
    /// tester is never confused about which app's data is in play during a relocate test.
    @ViewBuilder
    private var debugIsolationSection: some View {
        Section {
            Label("Debug build — using isolated data containers", systemImage: "ladybug.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            Text("Settings/state live in “\(AppSupportDirectory.folderName)”; the default notes folder is sandboxed. The installed app's data is untouched.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Output folder

    @ViewBuilder
    private var outputFolderSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Output Folder")
                        .font(.body)
                    Text(folderDisplay)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Change…") { pickFolder() }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(folderDropTargeted ? Color.accentColor : .clear, lineWidth: 2)
            )
            .onDrop(of: [.fileURL], isTargeted: $folderDropTargeted, perform: handleDrop)

            relocationStatusView
            destinationOfflineStatusView

            Text("Captured notes land here. Drop a folder above to change it. Existing notes move to the new folder automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Seed a starter scaffold in empty folders", isOn: seedScaffoldBinding)
            Text("When on, an empty folder with no `CLAUDE.md` gets a generic template `CLAUDE.md` with starter rules for an AI assistant reading your notes. Never touches a folder that already has content.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Notes Folder")
        }
    }

    /// Persists the toggle and, when switched on, seeds the *current* folder right away
    /// if it's eligible (empty + no CLAUDE.md). Turning it off only changes the setting.
    private var seedScaffoldBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.settings.seedScaffold },
            set: { newValue in
                appState.settings.update { $0.seedScaffold = newValue }
                if newValue, let folder = appState.settings.settings.outputFolder {
                    OutputFolderScaffold.seedIfEligible(folder: folder)
                }
            }
        )
    }

    @ViewBuilder
    private var destinationOfflineStatusView: some View {
        if appState.destinationOffline {
            let count = appState.queuedCaptureCount
            let counted = count > 0 ? " — \(count) \(count == 1 ? "capture" : "captures") queued" : ""
            Label {
                Text("Destination offline\(counted). Captures queue and file automatically when the drive reconnects.")
                    .font(.caption)
            } icon: {
                Image(systemName: "externaldrive.badge.exclamationmark")
            }
            .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var relocationStatusView: some View {
        switch appState.relocationStatus {
        case .inProgress:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Moving notes to the new folder…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        case .idle:
            EmptyView()
        }
    }

    private var folderDisplay: String {
        appState.settings.settings.outputFolder?.path(percentEncoded: false) ?? "—"
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        if let current = appState.settings.settings.outputFolder {
            panel.directoryURL = current
        }
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            Task { await appState.setOutputFolder(url) }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
            Task { @MainActor in
                await appState.setOutputFolder(url)
            }
        }
        return true
    }

    // MARK: - Launch at login

    @ViewBuilder
    private var launchAtLoginSection: some View {
        Section {
            Toggle("Start Rapture when I log in", isOn: launchAtLoginBinding)
            if let err = launchAtLoginError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if LaunchAtLoginController.status == .requiresApproval {
                Text("macOS needs you to approve this login item in System Settings → General → Login Items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { LaunchAtLoginController.isEnabled },
            set: { newValue in
                do {
                    try LaunchAtLoginController.setEnabled(newValue)
                    appState.settings.update { $0.launchAtLogin = newValue }
                    launchAtLoginError = nil
                } catch {
                    launchAtLoginError = "Couldn't \(newValue ? "enable" : "disable") launch at login: \(error.localizedDescription)"
                }
            }
        )
    }

    // MARK: - Reply mode

    @ViewBuilder
    private var replyModeSection: some View {
        Section {
            Picker("Reply Mode", selection: appState.settings.binding(for: \.replyMode)) {
                Text("Reply to every capture").tag(ReplyMode.all)
                Text("Reply on failures only").tag(ReplyMode.errorsOnly)
                Text("Never reply").tag(ReplyMode.off)
            }
            .pickerStyle(.inline)
            Text("Rapture posts a short confirmation in the same Messages thread the note arrived on. Disable replies if you don't want the confirmations.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Confirmation Replies")
        }
    }

    // MARK: - SMS

    @ViewBuilder
    private var smsSection: some View {
        Section {
            Toggle("Also capture from SMS / RCS senders", isOn: appState.settings.binding(for: \.allowSMS))
            Text("iMessage senders are verified by Apple. SMS sender IDs aren't — anyone can send a text claiming to be someone else. Off by default.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("SMS")
        }
    }

    // MARK: - Relay (Rapture iPhone app)

    @ViewBuilder
    private var relaySection: some View {
        Section {
            Toggle("File notes sent from the Rapture iPhone app", isOn: appState.settings.binding(for: \.relayEnabled))
            Text(relayStatusDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = appState.relayLastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("iPhone App")
        }
    }

    private var relayStatusDescription: String {
        switch appState.relayStatus {
        case .off:
            return "Relay capture is off. Notes sent from the iPhone app will wait in iCloud until you turn this back on."
        case .waitingForFolder:
            return "No relay folder yet. It appears automatically after the first note is sent from your iPhone."
        case .watching:
            return "Watching the iCloud relay folder. New notes are filed into your notes folder and removed from the relay."
        case .waitingForDownload(let count):
            return "Waiting for iCloud to download \(count) \(count == 1 ? "item" : "items")."
        }
    }
}
