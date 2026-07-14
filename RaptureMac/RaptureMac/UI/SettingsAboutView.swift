import AppKit
import SwiftUI

struct SettingsAboutView: View {
    @Environment(AppState.self) private var appState
    @Environment(UpdaterController.self) private var updater

    private static let repoURL = URL(string: "https://github.com/NoiseMeldOrg/rapture-mac")!

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Rapture")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(versionLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("Siri-dictated notes from a locked iPhone, filed as Markdown notes on your Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            Section("Open Source") {
                HStack {
                    Text("github.com/NoiseMeldOrg/rapture-mac")
                        .textSelection(.enabled)
                    Spacer()
                    Button("Open in Browser") {
                        NSWorkspace.shared.open(Self.repoURL)
                    }
                }
                Text("Apache-2.0 licensed. Pull requests welcome.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                if updater.isConfigured {
                    Toggle("Automatically check for updates", isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.automaticallyChecksForUpdates = $0 }
                    ))
                    HStack {
                        Text(lastCheckedLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Check for Updates…") { updater.checkForUpdates() }
                            .disabled(!updater.canCheckForUpdates)
                    }
                    Text("Updates are downloaded from GitHub Releases over a secure connection and verified before install. No usage data is sent. Turn the toggle off for no network checks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Auto-update isn't configured in this build (no signing key). Released builds update automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Diagnostics") {
                DisclosureGroup("Show paths and last error") {
                    diagnosticsBody
                }
            }
        }
        .formStyle(.grouped)
    }

    private var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "v\(short) (build \(build))"
    }

    private var lastCheckedLine: String {
        guard let date = updater.lastUpdateCheckDate else { return "Not checked yet" }
        return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    @ViewBuilder
    private var diagnosticsBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Output folder", value: appState.settings.settings.outputFolder?.path(percentEncoded: false) ?? "—")
            row("Settings file", value: filePath("settings.json"))
            row("State file", value: filePath("state.json"))

            if let err = appState.lastError {
                Divider()
                row("Last error", value: err)
                if let when = appState.lastErrorAt {
                    row("Last error at", value: when.formatted(date: .abbreviated, time: .shortened))
                }
            } else {
                Divider()
                Text("No recent errors.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func row(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private func filePath(_ name: String) -> String {
        do {
            return try AppSupportDirectory.url().appendingPathComponent(name).path(percentEncoded: false)
        } catch {
            return "—"
        }
    }
}
