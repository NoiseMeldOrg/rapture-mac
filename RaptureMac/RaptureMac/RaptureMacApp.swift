import AppKit
import SwiftUI

@main
struct RaptureMacApp: App {
    @State private var appState: AppState
    @State private var pipeline: Pipeline

    init() {
        let state = AppState()
        _appState = State(wrappedValue: state)
        _pipeline = State(wrappedValue: Pipeline(appState: state))
    }

    var body: some Scene {
        // Primary surface. Declared first so it serves as the "main scene" and the two Windows
        // below stay closed until explicitly invoked via openWindow(id:).
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            MenuBarLabel(start: { await pipeline.start() })
                .environment(appState)
        }
        .menuBarExtraStyle(.window)

        Window("Rapture for Mac", id: "permissions") {
            PermissionsView()
                .environment(appState)
                .frame(minWidth: 480, minHeight: 320)
                .task {
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowResizability(.contentSize)

        Window("Settings", id: "settings") {
            SettingsView()
                .environment(appState)
        }
        .windowResizability(.contentSize)
    }
}

/// The menu-bar icon view. Lives for the app's lifetime so its `.task` is a reliable
/// app-launch hook — that's where we kick off `pipeline.start()`.
private struct MenuBarLabel: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    let start: @MainActor () async -> Void

    @State private var didStart = false

    var body: some View {
        Image(systemName: iconName)
            .task {
                guard !didStart else { return }
                didStart = true
                await start()
                presentPermissionsIfNeeded(appState.permissionState)
            }
            .onChange(of: appState.permissionState) { _, newValue in
                presentPermissionsIfNeeded(newValue)
            }
    }

    private var iconName: String {
        if appState.permissionState != .ok {
            return "exclamationmark.triangle.fill"
        }
        if appState.automationPermissionState == .required {
            return "exclamationmark.triangle.fill"
        }
        if appState.settings.settings.paused {
            return "pause.fill"
        }
        return "text.bubble"
    }

    private func presentPermissionsIfNeeded(_ state: AppState.PermissionState) {
        guard state == .fullDiskAccessRequired else { return }
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "permissions")
    }
}
