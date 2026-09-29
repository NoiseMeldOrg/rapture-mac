import AppKit
import SwiftUI

/// Settings tabs. The selection lives on `AppState` so the menu can open a
/// specific tab (its "Activity…" row).
enum SettingsTab: Hashable { case general, triage, allowlist, activity, integrations, about }

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

            SettingsActivityView()
                .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
                .tag(SettingsTab.activity)

            SettingsIntegrationsView()
                .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
                .tag(SettingsTab.integrations)

            SettingsAboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .padding(20)
        .frame(width: 620, height: 560)
        .task {
            // LSUIElement quirk: ensure the window comes to front when opened from the menu bar.
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
