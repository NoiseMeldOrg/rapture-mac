import SwiftUI
import AppKit

struct PermissionsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismissWindow) private var dismissWindow

    private static let fdaSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Rapture needs Full Disk Access")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Rapture watches your Messages database so Siri-dictated notes can land as `.txt` files on your Mac. macOS requires Full Disk Access for any app that reads `~/Library/Messages/chat.db`.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Label("Click Open System Settings below.", systemImage: "1.circle")
                Label("Scroll to Rapture for Mac and turn the toggle on.", systemImage: "2.circle")
                Label("This window closes automatically once granted.", systemImage: "3.circle")
            }
            .font(.callout)

            Spacer()

            HStack {
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Open System Settings") {
                    NSWorkspace.shared.open(Self.fdaSettingsURL)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 320)
        .onChange(of: appState.permissionState) { _, newValue in
            if newValue == .ok {
                dismissWindow(id: "permissions")
            }
        }
    }
}
