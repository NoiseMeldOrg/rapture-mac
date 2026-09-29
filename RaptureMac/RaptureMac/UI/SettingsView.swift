import AppKit
import SwiftUI

/// Settings tabs. The selection lives on `AppState` so the menu's
/// "Settings…" row can always open on General.
enum SettingsTab: Hashable { case general, triage, allowlist, integrations, about }

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        TabView(selection: $appState.settingsTab) {
            SettingsGeneralView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            SettingsTriageView()
                .tabItem { Label("Triage", systemImage: "tray.full") }
                .tag(SettingsTab.triage)

            SettingsAllowlistView()
                .tabItem { Label("Allowlist", systemImage: "person.crop.circle.badge.checkmark") }
                .tag(SettingsTab.allowlist)

            SettingsIntegrationsView()
                .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
                .tag(SettingsTab.integrations)

            SettingsAboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .padding(20)
        // Wide enough that all five tabs show without macOS folding them into
        // a "»" overflow menu, with room to spare for longer localized names.
        .frame(width: 760, height: 600)
        .task {
            // LSUIElement quirk: ensure the window comes to front when opened from the menu bar.
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
