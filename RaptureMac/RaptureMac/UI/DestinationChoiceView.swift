import AppKit
import SwiftUI

/// First-run step two, after Full Disk Access: where should notes go? Lists
/// the vaults and sync folders found on this Mac, any other folder, and an
/// explicit "Keep the default". Capture already works meanwhile: notes land in
/// the default folder and move when a place is picked.
struct DestinationChoiceView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var detected: [DetectedDestination] = []
    @State private var answered = false
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Where should your notes go?")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Pick the folder you already keep notes in, so your captures land with the rest. You can change it later in Settings → General.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(detected) { place in
                    Button {
                        pick(place.path)
                    } label: {
                        HStack {
                            Image(systemName: place.isVault ? "books.vertical" : "icloud")
                                .frame(width: 18)
                            Text(place.reachable ? place.label : "\(place.label) (drive not connected)")
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .disabled(!place.reachable || working)
                }
                Button {
                    chooseOther()
                } label: {
                    HStack {
                        Image(systemName: "folder").frame(width: 18)
                        Text("Choose Another Folder…")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .disabled(working)
            }
            .buttonStyle(.bordered)

            Spacer()

            HStack {
                Text("Default: \(AppSupportDirectory.defaultOutputFolder.path(percentEncoded: false))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Keep the Default") {
                    DestinationChoiceFlow.keepDefault(appState: appState)
                    answered = true
                    dismissWindow(id: "destination")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 360)
        .task {
            NSApp.activate(ignoringOtherApps: true)
            detected = await Task.detached(priority: .userInitiated) { DestinationDetector.detect() }.value
        }
        .onDisappear {
            // Closed without an answer: stop asking at launch, but leave the
            // question open for the menu nudge.
            if !answered { DestinationChoiceFlow.dismiss(appState: appState) }
        }
    }

    private func pick(_ url: URL) {
        working = true
        Task {
            if await DestinationChoiceFlow.choose(url, appState: appState) {
                answered = true
                dismissWindow(id: "destination")
            }
            working = false
        }
    }

    private func chooseOther() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            pick(url)
        }
    }
}
