import SwiftUI

/// The link-enrichment section of the Triage tab: one toggle, an honest
/// network line, and the quiet-failure status. Independent of AI triage — a
/// plain settings bind (no enable flow: no TCC, no key, nothing to verify).
/// The nested auto-transcribe toggle drives the transcript dispatcher (see
/// `TranscriptDispatch/`); it only means anything while enrichment is on.
struct LinkEnrichmentSettingsSection: View {
    @Environment(AppState.self) private var appState
    @Environment(TranscriptDispatchService.self) private var transcriptDispatch

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
            if appState.settings.settings.linkEnrichmentEnabled {
                Toggle("Auto-transcribe YouTube captures", isOn: appState.settings.binding(for: \.autoTranscribeYouTube))
                Text(transcribeCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if appState.settings.settings.autoTranscribeYouTube {
                    if let error = appState.transcriptDispatchLastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if failedDispatchCount > 0 {
                        Button("Retry failed (\(failedDispatchCount))") {
                            transcriptDispatch.retryFailed()
                        }
                    }
                }
            }
        } header: {
            Text("Link Enrichment")
        }
    }

    private var failedDispatchCount: Int {
        appState.state.state.transcriptDispatchRecords.filter { $0.status == .failed }.count
    }

    private var caption: String {
        if appState.settings.settings.linkEnrichmentEnabled {
            return "When a captured link files, the app fetches the YouTube transcript or the article's readable text into Links/Media/ and renames the note to the real title. Only the link's URL is sent — never your note text. Best-effort: if a fetch fails, the note simply stays as filed."
        }
        return "Off: link captures file with a plain URL title and nothing is fetched. Turning this on downloads YouTube transcripts and article text next to your link notes."
    }

    private var transcribeCaption: String {
        if appState.settings.settings.autoTranscribeYouTube {
            return "When a YouTube capture finishes enriching, the app launches your own locally installed Claude Code agent (one session at a time) to run your transcript pipeline, save the polished transcript into Links/Media/, and link it in the note. Does nothing unless that agent setup exists on this Mac; the app itself opens no connection."
        }
        return "Off: enriched YouTube captures are not handed to your local transcript pipeline."
    }
}
