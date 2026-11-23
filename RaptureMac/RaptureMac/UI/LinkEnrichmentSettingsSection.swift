import AppKit
import SwiftUI

/// The link-enrichment section of the Triage tab: one toggle, an honest
/// network line, and the quiet-failure status. Independent of AI triage — a
/// plain settings bind (no enable flow: no TCC, no key, nothing to verify).
/// The two nested auto-transcribe toggles (YouTube; Facebook and X videos)
/// drive the transcript dispatcher (see `TranscriptDispatch/`); they only mean
/// anything while enrichment is on. Under them sit the pipeline folder both
/// share, a chooser, and one status line. The folder is the user's choice, so
/// "not set" and "not found" are said here plainly instead of the feature
/// going quiet.
struct LinkEnrichmentSettingsSection: View {
    @Environment(AppState.self) private var appState
    @Environment(TranscriptDispatchService.self) private var transcriptDispatch

    /// The last disk check of the pipeline folder, with the setting it was
    /// made for (so a stale result is never shown against a new path).
    @State private var checkedPipelineFolder: (setting: String?, status: TranscriptDispatch.PipelineFolderStatus)?

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
                Toggle("Auto-transcribe Facebook and X videos", isOn: appState.settings.binding(for: \.autoTranscribeSocialVideos))
                Text(socialTranscribeCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if autoTranscribeAnything {
                    pipelineFolderRow
                    pipelineFolderStatusLine
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

    // MARK: - Pipeline folder

    private var pipelineFolderSetting: String? {
        appState.settings.settings.transcriptPipelineFolder
    }

    /// Not set needs no disk check, so it shows at once. Otherwise the last
    /// check for this exact setting, or nil for the instant before it lands.
    private var pipelineFolderStatus: TranscriptDispatch.PipelineFolderStatus? {
        guard TranscriptDispatch.pipelineFolderURL(fromSetting: pipelineFolderSetting) != nil else { return .notSet }
        guard let checked = checkedPipelineFolder, checked.setting == pipelineFolderSetting else { return nil }
        return checked.status
    }

    private var pipelineFolderDisplay: String {
        guard let url = TranscriptDispatch.pipelineFolderURL(fromSetting: pipelineFolderSetting) else {
            return "No folder chosen"
        }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }

    @ViewBuilder
    private var pipelineFolderRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pipeline Folder")
                Text(pipelineFolderDisplay)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Choose…") { pickPipelineFolder() }
        }
        // On this one row (not the Section, where a modifier can fan out to
        // every row). Re-checks while Settings is open: a folder that is
        // moved, or a drive that is plugged back in, shows without reopening
        // the window. The disk check stays off the main actor.
        .task(id: pipelineFolderSetting) {
            let setting = pipelineFolderSetting
            while !Task.isCancelled {
                let status = await Task.detached(priority: .utility) {
                    TranscriptDispatch.pipelineFolderStatus(setting: setting)
                }.value
                if Task.isCancelled { break }
                checkedPipelineFolder = (setting, status)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    @ViewBuilder
    private var pipelineFolderStatusLine: some View {
        switch pipelineFolderStatus {
        case .notSet:
            Label {
                Text("Not set. Nothing is transcribed until you choose the folder your transcript pipeline runs in.")
                    .font(.caption)
            } icon: {
                Image(systemName: "folder.badge.questionmark")
            }
            .foregroundStyle(.orange)
        case .missing:
            // The path is on the row above; it is not repeated here.
            Label {
                Text("Folder not found. Nothing is transcribed until it is back or you choose another folder.")
                    .font(.caption)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(.red)
        case .ready:
            Label {
                Text("Ready. Each session runs in this folder.")
                    .font(.caption)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }

    /// Folders only. The app is unsandboxed, so the plain path is stored — no
    /// security-scoped bookmark. Takes effect at the next dispatch, no restart.
    private func pickPipelineFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose the folder your transcript pipeline runs in."
        if case .ready(let current) = TranscriptDispatch.pipelineFolderStatus(setting: pipelineFolderSetting) {
            panel.directoryURL = current
        }
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            appState.settings.update { $0.transcriptPipelineFolder = url.path }
        }
    }

    /// The folder row and status show while either toggle is on.
    private var autoTranscribeAnything: Bool {
        let settings = appState.settings.settings
        return settings.autoTranscribeYouTube || settings.autoTranscribeSocialVideos
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
            return "When a YouTube capture finishes enriching, the app launches your own locally installed Claude Code agent (one session at a time) in the pipeline folder below to run your transcript pipeline, save the polished transcript into Links/Media/, and link it in the note. Does nothing until you choose that folder; the app itself opens no connection."
        }
        return "Off: enriched YouTube captures are not handed to your local transcript pipeline."
    }

    private var socialTranscribeCaption: String {
        if appState.settings.settings.autoTranscribeSocialVideos {
            return "When a Facebook or X post that holds a video finishes enriching, the app launches your own locally installed Claude Code agent (one session at a time, shared with the YouTube setting) in the pipeline folder to run your social post transcript pipeline, save the transcript into Links/Media/, and link it in the note. Each video is one session under your own Claude Code account, so it uses your own usage. Instagram and Threads videos are never sent. Does nothing until you choose the pipeline folder; the app itself opens no connection."
        }
        return "Off: enriched Facebook and X video posts are not handed to your local transcript pipeline."
    }
}
