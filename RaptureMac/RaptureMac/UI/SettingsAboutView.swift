import AppKit
import SwiftUI

struct SettingsAboutView: View {
    @Environment(AppState.self) private var appState

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
                    Text("Siri-dictated notes from a locked iPhone, landing as `.txt` files on your Mac.")
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
