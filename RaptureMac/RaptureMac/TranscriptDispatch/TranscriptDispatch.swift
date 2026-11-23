import Foundation

/// The post-enrichment dispatch seam. `LinkEnrichmentService` calls this the
/// moment a YouTube capture, or a Facebook or X video post, finishes
/// enriching; the implementation only enqueues (a ledger append, the
/// `noteFiled` discipline) and never blocks, because the call happens inside
/// the capture gate.
@MainActor
protocol TranscriptDispatching: AnyObject {
    func captureEnriched(fingerprint: String, url: String, noteRelativePath: String)
}

/// The session-spawn seam. Tests inject `FakeTranscriptSessionLauncher`; the
/// app uses `ClaudeProcessSessionLauncher`. `@MainActor` mirrors
/// `GitStateReading`: the front-guard reads the MainActor-isolated
/// `isRunningXCTests`, and the real launcher never blocks the main actor
/// (spawn returns as soon as the child is running).
@MainActor
protocol TranscriptSessionLaunching: AnyObject {
    func launch(prompt: String, workingDirectory: URL) async throws
    func isRunning() -> Bool
    func terminate()
    /// Forensics for a session that ended without producing a transcript link
    /// (exit code + stderr tail). Nil while running or when nothing useful.
    func lastFailureDetail() -> String?
}

/// Launch failures. `.unavailableUnderTests` is the XCTest front-guard result
/// (the hosted suite never spawns a real `claude`), mirroring `GitReadError`.
enum TranscriptSessionError: Error, Equatable, Sendable {
    case unavailableUnderTests
    case spawnFailed(String)
}

/// Pure, test-locked pieces of the dispatch contract. Rapture contains no
/// pipeline logic — the transcript pipeline itself lives in the user's own
/// pipeline folder (its AGENTS.md, "YouTube URL → Drive Transcript" and
/// "Social Post URL → Drive Transcript"); the app only points a Claude Code
/// session at it.
enum TranscriptDispatch {
    /// Where the pipeline folder stands right now. The folder comes only from
    /// `Settings.transcriptPipelineFolder` — the app ships publicly, so there
    /// is no built-in path and no fallback. `.notSet` means the feature is off.
    enum PipelineFolderStatus: Equatable, Sendable {
        case notSet
        /// A path is set but no directory is there (moved, renamed, or on an
        /// unplugged drive).
        case missing(URL)
        case ready(URL)

        /// Why a dispatch was skipped, for the log line. Nil when ready.
        nonisolated var skipReason: String? {
            switch self {
            case .notSet: return "the pipeline folder is not set"
            case .missing(let url): return "the pipeline folder was not found at \(url.path)"
            case .ready: return nil
            }
        }
    }

    /// The setting as a folder URL: trimmed, leading `~` expanded. Nil when
    /// the setting is absent or blank. Does not touch the disk.
    nonisolated static func pipelineFolderURL(fromSetting path: String?) -> URL? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Resolves the setting against the disk. A path that is a file, not a
    /// folder, counts as missing — a session cannot run in it.
    nonisolated static func pipelineFolderStatus(
        setting path: String?,
        fileManager: FileManager = .default
    ) -> PipelineFolderStatus {
        guard let url = pipelineFolderURL(fromSetting: path) else { return .notSet }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .missing(url)
        }
        return .ready(url)
    }

    /// Where the polished transcript lands: the note's sibling `Media/` folder
    /// (beside the raw-captions enrichment artifact), suffixed so the two
    /// never collide. `"Links/2026-08-31 Talk.md"` →
    /// `"Links/Media/2026-08-31 Talk Transcript.md"`.
    nonisolated static func transcriptRelativePath(forNoteRelativePath notePath: String) -> String {
        let ns = notePath as NSString
        let dir = ns.deletingLastPathComponent
        let base = (ns.lastPathComponent as NSString).deletingPathExtension
        let mediaDir = dir.isEmpty ? "Media" : dir + "/Media"
        return mediaDir + "/" + base + " Transcript.md"
    }

    /// The exact line the agent appends to the note — fully interpolated by
    /// the app so the agent applies no judgment (house `Media:` link style:
    /// one hop down from the note, angle-bracketed for spaces).
    nonisolated static func transcriptLine(transcriptFilename: String) -> String {
        let base = (transcriptFilename as NSString).deletingPathExtension
        return "Transcript: [\(base)](<Media/\(transcriptFilename)>)"
    }

    /// What a queued capture is: a YouTube video, or a Facebook or X video post.
    /// Each has its own toggle (`autoTranscribeYouTube`, `autoTranscribeSocialVideos`).
    enum Kind: Equatable, Sendable {
        case youtube
        case socialVideo
    }

    /// The kind of capture a fingerprint and URL describe, or nil when the
    /// dispatcher must ignore it. YouTube is `yt:`. A social video is a `url:`
    /// fingerprint on a Facebook or X host (Instagram and Threads videos are
    /// never transcribed: the pipeline cannot read them without a browser
    /// login). Whether a Facebook or X post really is a video is decided
    /// upstream, by `LinkEnrichmentService`, before it calls the dispatcher.
    nonisolated static func kind(fingerprint: String, url: String) -> Kind? {
        if fingerprint.hasPrefix("yt:") { return .youtube }
        guard fingerprint.hasPrefix("url:"),
              let parsed = URL(string: url),
              let platform = SocialPost.platform(for: parsed),
              platform.canTranscribeVideo else { return nil }
        return .socialVideo
    }

    /// The pipeline name in the first line of each prompt. These two names are
    /// a contract with the pipeline folder's AGENTS.md; do not change them.
    nonisolated static let youTubePipelineName = "YouTube URL → Drive Transcript"
    nonisolated static let socialPostPipelineName = "Social Post URL → Drive Transcript"

    /// The fixed prompt handed to `claude -p`. Stability is the contract with
    /// the agent side — locked by an exact-string unit test. Both absolute
    /// paths are resolved at spawn time against the current output folder.
    /// The pipeline is invoked by name but its output is overridden: a local
    /// Markdown transcript in the vault, not a Google Doc.
    nonisolated static func prompt(
        url: String,
        noteAbsolutePath: String,
        transcriptAbsolutePath: String,
        transcriptLine: String
    ) -> String {
        composePrompt(
            pipelineName: youTubePipelineName, url: url, noteAbsolutePath: noteAbsolutePath,
            transcriptAbsolutePath: transcriptAbsolutePath, transcriptLine: transcriptLine)
    }

    /// The same prompt for a Facebook or X video post. Identical to `prompt`
    /// except the first line, which names the social post pipeline. Also locked
    /// by an exact-string unit test.
    nonisolated static func socialPostPrompt(
        url: String,
        noteAbsolutePath: String,
        transcriptAbsolutePath: String,
        transcriptLine: String
    ) -> String {
        composePrompt(
            pipelineName: socialPostPipelineName, url: url, noteAbsolutePath: noteAbsolutePath,
            transcriptAbsolutePath: transcriptAbsolutePath, transcriptLine: transcriptLine)
    }

    /// The prompt to spawn a session with, chosen from the URL's host when the
    /// session starts (so the ledger and `state.json` carry no extra field): the
    /// social post prompt for a Facebook, Instagram, Threads or X link, the
    /// YouTube prompt for everything else (including entries queued before the
    /// social pipeline existed).
    nonisolated static func pipelinePrompt(
        forURL url: String,
        noteAbsolutePath: String,
        transcriptAbsolutePath: String,
        transcriptLine: String
    ) -> String {
        let isSocial = URL(string: url).flatMap(SocialPost.platform(for:)) != nil
        if isSocial {
            return socialPostPrompt(
                url: url, noteAbsolutePath: noteAbsolutePath,
                transcriptAbsolutePath: transcriptAbsolutePath, transcriptLine: transcriptLine)
        }
        return prompt(
            url: url, noteAbsolutePath: noteAbsolutePath,
            transcriptAbsolutePath: transcriptAbsolutePath, transcriptLine: transcriptLine)
    }

    private nonisolated static func composePrompt(
        pipelineName: String,
        url: String,
        noteAbsolutePath: String,
        transcriptAbsolutePath: String,
        transcriptLine: String
    ) -> String {
        """
        Run the "\(pipelineName)" pipeline defined in AGENTS.md on this URL: \(url)

        Two overrides for this run: skip the ack reply and do not reply anywhere else, and do NOT create a Google Doc — write the full cleaned-up transcript as a Markdown file at \(transcriptAbsolutePath) instead.

        After that file exists, append exactly this one line to the end of the Markdown note at \(noteAbsolutePath):

        \(transcriptLine)

        Change nothing else in the note. If the pipeline fails, write no transcript file and leave the note untouched.
        """
    }

    /// Success is judged by the note, not the session: done when any line
    /// starts with `Transcript:` (the contract line above — app-composed link
    /// notes never write one on their own). A `docs.google.com` /
    /// `drive.google.com` substring also counts, so a note the old
    /// Drive-pipeline already served is recognized as satisfied and never
    /// re-dispatched.
    nonisolated static func containsTranscriptMarker(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains("docs.google.com") || lowered.contains("drive.google.com") { return true }
        return lowered.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("transcript:")
        }
    }
}
