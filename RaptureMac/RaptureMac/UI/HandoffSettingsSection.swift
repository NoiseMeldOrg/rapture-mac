import SwiftUI

/// Settings → General → "Reminders & Calendar": the two independent handoff
/// toggles (off by default), target pickers shown while enabled, a plain
/// caption, and the last handoff error. Enabling a toggle drives the pre-prompt
/// → TCC request flow (`HandoffEnableFlow`); the toggle only persists ON after
/// the grant lands, so there's no optimistic flicker.
struct HandoffSettingsSection: View {
    @Environment(AppState.self) private var appState

    @State private var reminderTargets: [HandoffTarget] = []
    @State private var calendarTargets: [HandoffTarget] = []

    var body: some View {
        Section {
            Toggle(
                "Create Reminders from “remind me…” captures",
                isOn: toggleBinding(for: .reminder, keyPath: \.remindersHandoffEnabled)
            )
            if appState.settings.settings.remindersHandoffEnabled {
                targetPicker(
                    label: "Add to list",
                    defaultLabel: "Default list",
                    targets: reminderTargets,
                    selection: appState.settings.binding(for: \.remindersListID)
                )
            }

            Toggle(
                "Create Calendar events from stated appointments",
                isOn: toggleBinding(for: .event, keyPath: \.calendarHandoffEnabled)
            )
            if appState.settings.settings.calendarHandoffEnabled {
                targetPicker(
                    label: "Add to calendar",
                    defaultLabel: "Default calendar",
                    targets: calendarTargets,
                    selection: appState.settings.binding(for: \.calendarID)
                )
            }

            Text("A capture that clearly says “remind me to…” becomes a Reminder; a stated appointment with a date and time becomes a 1-hour event. The note always files either way, the created item keeps the full dictation in its notes, and anything ambiguous just files. Dates read relative to when the note was dictated.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = appState.handoffLastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Reminders & Calendar")
        }
        .onAppear { loadTargets() }
    }

    @ViewBuilder
    private func targetPicker(
        label: String,
        defaultLabel: String,
        targets: [HandoffTarget],
        selection: Binding<String?>
    ) -> some View {
        Picker(label, selection: selection) {
            Text(defaultLabel).tag(String?.none)
            ForEach(targets) { target in
                Text(target.title).tag(String?.some(target.id))
            }
            // A stored ID whose list/calendar no longer exists still renders
            // (creation falls back to the system default either way).
            if let current = selection.wrappedValue, !targets.contains(where: { $0.id == current }) {
                Text("Missing target (uses default)").tag(String?.some(current))
            }
        }
    }

    private func toggleBinding(
        for kind: HandoffKind,
        keyPath: WritableKeyPath<Settings, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { appState.settings.settings[keyPath: keyPath] },
            set: { newValue in
                guard newValue else {
                    appState.settings.update { $0[keyPath: keyPath] = false }
                    return
                }
                // The getter keeps reporting false until the grant lands, so
                // the visual toggle doesn't flick on optimistically.
                Task { @MainActor in
                    let result = await HandoffEnableFlow.enable(
                        kind: kind,
                        client: appState.eventKit,
                        prePrompt: { HandoffPrompt.showPrePrompt(kind: kind) == .proceed },
                        showDenied: { HandoffPrompt.showDenied(kind: kind) }
                    )
                    if result.enabled {
                        appState.settings.update { $0[keyPath: keyPath] = true }
                        appState.handoffLastError = nil
                        loadTargets()
                    } else if let error = result.error {
                        appState.handoffLastError = error
                    }
                }
            }
        )
    }

    /// Lists load only while the toggle is on AND access is granted — the
    /// Settings window opening must never touch EventKit otherwise.
    private func loadTargets() {
        let settings = appState.settings.settings
        if settings.remindersHandoffEnabled,
           appState.eventKit.authorizationStatus(for: .reminder) == .authorized {
            reminderTargets = appState.eventKit.targets(for: .reminder)
        }
        if settings.calendarHandoffEnabled,
           appState.eventKit.authorizationStatus(for: .event) == .authorized {
            calendarTargets = appState.eventKit.targets(for: .event)
        }
    }
}
