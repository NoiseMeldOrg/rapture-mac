import SwiftUI

/// The Triage tab: everything about what happens to a capture after it lands —
/// filing mode, the AI tier, link enrichment, and the Reminders/Calendar
/// handoff (moved here from General, which was outgrowing its window).
struct SettingsTriageView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            triageSection
            AITriageSettingsSection()
            LinkEnrichmentSettingsSection()
            HandoffSettingsSection()
        }
        .formStyle(.grouped)
    }

    // MARK: - Filing mode (moved verbatim from SettingsGeneralView)

    @ViewBuilder
    private var triageSection: some View {
        Section {
            Picker("Filing", selection: appState.settings.binding(for: \.triageMode)) {
                Text("Markdown notes, sorted into folders (recommended)").tag(TriageMode.full)
                Text("Raw text files, no triage").tag(TriageMode.raw)
            }
            .pickerStyle(.inline)
            Text(triageStatusDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = appState.triageLastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Filing")
        }
    }

    private var triageStatusDescription: String {
        switch appState.triageStatus {
        case .off:
            return "Captures land as raw .txt files at the folder root — the pre-triage behavior. Nothing is converted."
        case .waitingForFolder:
            return "Waiting for an output folder to be configured."
        case .watching:
            return "Every capture becomes a Markdown note with a small header, filed into Notes/ or Links/ — plus Tasks/, Ideas/, and Journal/ with AI triage on. Text files dropped at the folder root are converted too."
        case .waitingForDownload(let count):
            return "Waiting for iCloud to download \(count) pending \(count == 1 ? "file" : "files") at the folder root."
        case .triaging(let done, let total):
            return "Triaging notes… \(done) of \(total)."
        }
    }
}
