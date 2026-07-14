import SwiftUI

/// The link-enrichment section of the Triage tab: one toggle, an honest
/// network line, and the quiet-failure status. Independent of AI triage — a
/// plain settings bind (no enable flow: no TCC, no key, nothing to verify).
struct LinkEnrichmentSettingsSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Section {
            Toggle("Fetch transcripts and articles", isOn: appState.settings.binding(for: \.linkEnrichmentEnabled))
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            if appState.settings.settings.linkEnrichmentEnabled,
               let error = appState.enrichmentLastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Link Enrichment")
        }
    }

    private var caption: String {
        if appState.settings.settings.linkEnrichmentEnabled {
            return "When a captured link files, the app fetches the YouTube transcript or the article's readable text into Links/Media/ and renames the note to the real title. Only the link's URL is sent — never your note text. Best-effort: if a fetch fails, the note simply stays as filed."
        }
        return "Off: link captures file with a plain URL title and nothing is fetched. Turning this on downloads YouTube transcripts and article text next to your link notes."
    }
}
