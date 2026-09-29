import AppKit
import SwiftUI

/// The Activity window: what the app did, newest first, plus anything still
/// wrong. Read from `ActivityLog` (local file, titles and paths only). Its own
/// window, not a Settings tab: it is a record, not a setting, and a sixth tab
/// no longer fit the Settings tab bar.
struct ActivityView: View {
    @Environment(AppState.self) private var appState
    @State private var confirmClear = false

    var body: some View {
        Form {
            if !appState.errors.isEmpty {
                Section {
                    ForEach(appState.errors.sorted { $0.at > $1.at }, id: \.source) { error in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(error.message)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(Self.relative(error.at))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Dismiss All") { appState.dismissAllErrors() }
                } header: {
                    Text("Needs Attention")
                }
            }

            Section {
                if appState.activity.recent.isEmpty {
                    Text("Nothing yet. Each capture, reminder, and problem shows up here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.activity.recent) { event in
                        ActivityRow(event: event)
                    }
                }
            } header: {
                Text("Recent Activity")
            } footer: {
                HStack {
                    Text("Kept only on this Mac. Titles and file locations, never note text.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear History…") { confirmClear = true }
                        .disabled(appState.activity.recent.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, idealWidth: 620, minHeight: 420, idealHeight: 560)
        .task {
            // LSUIElement quirk: bring the window to front when opened from the menu bar.
            NSApp.activate(ignoringOtherApps: true)
        }
        .confirmationDialog("Clear the activity history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { appState.activity.clear() }
        } message: {
            Text("Your notes are not touched. Only this list is emptied.")
        }
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct ActivityRow: View {
    let event: ActivityEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: Self.symbol(event.kind))
                .foregroundStyle(Self.tint(event.kind))
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.summary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text("\(event.source.displayName) · \(event.at.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let path = event.path, FileManager.default.fileExists(atPath: path) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func symbol(_ kind: ActivityEvent.Kind) -> String {
        switch kind {
        case .filed: return "doc.text"
        case .meetingFiled, .meetingUpdated: return "person.2"
        case .queued: return "tray.and.arrow.down"
        case .failed, .gaveUp, .attachmentMissing, .warning: return "exclamationmark.triangle"
        case .attachmentRecovered: return "paperclip"
        case .reminderCreated: return "checklist"
        case .eventCreated: return "calendar"
        case .enriched: return "link"
        case .info: return "info.circle"
        }
    }

    static func tint(_ kind: ActivityEvent.Kind) -> Color {
        switch kind {
        case .failed, .gaveUp, .attachmentMissing, .warning: return .orange
        default: return .secondary
        }
    }
}
