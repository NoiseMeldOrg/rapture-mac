import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    private enum Tab: Hashable { case general, allowlist, about }
    @State private var tab: Tab = .general

    var body: some View {
        TabView(selection: $tab) {
            SettingsGeneralView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)

            SettingsAllowlistView()
                .tabItem { Label("Allowlist", systemImage: "person.crop.circle.badge.checkmark") }
                .tag(Tab.allowlist)

            SettingsAboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        .padding(20)
        .frame(width: 560, height: 440)
        .task {
            // LSUIElement quirk: ensure the window comes to front when opened from the menu bar.
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
