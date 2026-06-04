import AppKit
import SwiftUI

// MARK: - Tab root

struct SettingsIntegrationsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if appState.integrations.cards.isEmpty {
                    emptyState
                } else {
                    ForEach(appState.integrations.cards) { card in
                        ConsumerCardView(card: card)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .onAppear {
            appState.integrations.startPolling()
        }
        .onDisappear {
            appState.integrations.stopPolling()
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        Text("No integrations discovered in examples/. Add a folder under examples/ in the repo and rebuild the app.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding()
    }
}

// MARK: - Consumer card

struct ConsumerCardView: View {
    let card: ConsumerCard
    @Environment(AppState.self) private var appState

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(card.displayName)
                    .font(.headline)
                if !card.description.isEmpty {
                    Text(card.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                cardActions

                if card.installs.isEmpty {
                    infoCardFooter
                } else {
                    ForEach(card.installs) { install in
                        Divider()
                        InstallSectionView(install: install)
                    }
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var cardActions: some View {
        HStack(spacing: 8) {
            ForEach(card.docs) { doc in
                Button(doc.label) {
                    NSWorkspace.shared.open(doc.fileURL)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Button("Open in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([card.folderURL])
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer()
        }
    }

    @ViewBuilder
    private var infoCardFooter: some View {
        Text("This integration is documentation-only in the app. Follow the README to install manually.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Install profile section

struct InstallSectionView: View {
    let install: InstallProfile
    @Environment(AppState.self) private var appState
    @State private var expanded: Bool = true

    private var statusPill: StatusPill {
        pillForInstall(install, status: appState.integrations.status)
    }

    private var pendingAction: IntegrationsState.ActionState {
        appState.integrations.pendingActions[install.id] ?? .idle
    }

    private var prereqs: PrerequisiteReport? {
        appState.integrations.prereqs[install.id]
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if !install.description.isEmpty {
                    Text(install.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                actionRow

                if let prereqs, !prereqs.missingItems.isEmpty {
                    missingPrereqsView(prereqs.missingItems)
                }

                if let prereqs, !prereqs.tccDeepLinks.isEmpty {
                    tccRow(prereqs.tccDeepLinks)
                }

                statusFootnote
            }
            .padding(.vertical, 6)
        } label: {
            HStack {
                Text(install.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                StatusPillView(pill: statusPill)
            }
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 8) {
            if install.install != nil {
                Button(action: { dispatch(.install) }) {
                    Text("Install…")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(pendingAction == .running)
            }
            if install.uninstall != nil {
                Button(action: { dispatch(.uninstall) }) {
                    Text("Uninstall")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(pendingAction == .running)
            }
            if pendingAction == .running {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func missingPrereqsView(_ items: [MissingItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Missing prerequisites:")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(items) { item in
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Text(item.installCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    Button(action: { copyToPasteboard(item.installCommand) }) {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Copy command")
                }
            }
        }
    }

    @ViewBuilder
    private func tccRow(_ entries: [TCCEntry]) -> some View {
        HStack(spacing: 8) {
            Text("Permissions:")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(entries) { entry in
                Button("Grant \(entry.name)…") {
                    NSWorkspace.shared.open(entry.url)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var statusFootnote: some View {
        switch pendingAction {
        case .idle:
            EmptyView()
        case .running:
            EmptyView()
        case .succeeded:
            Label("Done.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 2) {
                Label("Failed.", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func dispatch(_ action: IntegrationsState.ActionKind) {
        Task { @MainActor in
            await appState.integrations.run(action, for: install, env: [:])
        }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

// MARK: - Status pill

enum StatusPill: Equatable {
    case notInstalled
    case installed
    case partiallyInstalled
    case unknown
}

struct StatusPillView: View {
    let pill: StatusPill

    var body: some View {
        Text(label)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
            .foregroundStyle(foreground)
    }

    private var label: String {
        switch pill {
        case .notInstalled:        return "Not installed"
        case .installed:           return "Installed"
        case .partiallyInstalled:  return "Partial"
        case .unknown:             return "Unknown"
        }
    }

    private var background: Color {
        switch pill {
        case .notInstalled:        return .secondary.opacity(0.18)
        case .installed:           return .green.opacity(0.20)
        case .partiallyInstalled:  return .yellow.opacity(0.25)
        case .unknown:             return .secondary.opacity(0.18)
        }
    }

    private var foreground: Color {
        switch pill {
        case .notInstalled, .unknown:    return .secondary
        case .installed:                 return .green
        case .partiallyInstalled:        return .orange
        }
    }
}

// MARK: - StatusPill resolution

/// Maps a StatusReport + InstallProfile to a StatusPill. Pure logic so it can be
/// tested without instantiating a view.
nonisolated func pillForInstall(_ install: InstallProfile, status: StatusReport?) -> StatusPill {
    guard let status, let key = install.statusKey else { return .notInstalled }

    switch key {
    case .hook:
        switch (status.hook.scriptInstalled, status.hook.registered) {
        case (false, _):       return .notInstalled
        case (true, false):    return .partiallyInstalled
        case (true, true):     return .installed
        }
    case .unknown:
        return .unknown
    }
}
