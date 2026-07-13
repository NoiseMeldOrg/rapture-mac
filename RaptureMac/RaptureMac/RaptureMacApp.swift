import AppKit
import SwiftUI

@main
struct RaptureMacApp: App {
    // DEBUG builds run against isolated Application Support + notes containers
    // (see AppSupportDirectory); the title marker makes it obvious which build is driven.
    static let settingsWindowTitle = AppSupportDirectory.isDebugContainer ? "Settings (Debug)" : "Settings"

    @State private var appState: AppState
    @State private var pipeline: Pipeline
    @State private var updater: UpdaterController

    init() {
        let state = AppState()
        _appState = State(wrappedValue: state)
        _pipeline = State(wrappedValue: Pipeline(appState: state))
        _updater = State(wrappedValue: UpdaterController())
    }

    var body: some Scene {
        // Primary surface. Declared first so it serves as the "main scene" and the two Windows
        // below stay closed until explicitly invoked via openWindow(id:).
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
                .environment(updater)
        } label: {
            MenuBarLabel(start: { await pipeline.start() })
                .environment(appState)
        }
        .menuBarExtraStyle(.window)

        Window("Rapture", id: "permissions") {
            PermissionsView()
                .environment(appState)
                .frame(minWidth: 480, minHeight: 320)
                .task {
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowResizability(.contentSize)

        Window(Self.settingsWindowTitle, id: "settings") {
            SettingsView()
                .environment(appState)
                .environment(updater)
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
        iconView
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

    // Brand mark for the normal "capturing" state; SF Symbols for permission /
    // automation / paused states because those communicate clearly across all apps.
    // MenuBarIcon.imageset uses template-rendering-intent so macOS handles the
    // light/dark menu-bar inversion automatically.
    @ViewBuilder
    private var iconView: some View {
        if let systemSymbol = systemIconName {
            Image(systemName: systemSymbol)
        } else {
            Image("MenuBarIcon")
        }
    }

    private var systemIconName: String? {
        if appState.permissionState != .ok {
            return "exclamationmark.triangle.fill"
        }
        if appState.automationPermissionState == .required {
            return "exclamationmark.triangle.fill"
        }
        if appState.settings.settings.paused {
            return "pause.fill"
        }
        if appState.destinationOffline {
            return "exclamationmark.triangle.fill"
        }
        return nil
    }

    private func presentPermissionsIfNeeded(_ state: AppState.PermissionState) {
        guard state == .fullDiskAccessRequired else { return }
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "permissions")
    }
}
