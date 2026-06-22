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
            outputFolderSection
            launchAtLoginSection
            replyModeSection
            smsSection
        }
        .formStyle(.grouped)
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

            Text("Captured notes land here as `.txt` files. Drop a folder above to change it. Existing notes move to the new folder automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Notes Folder")
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
}
