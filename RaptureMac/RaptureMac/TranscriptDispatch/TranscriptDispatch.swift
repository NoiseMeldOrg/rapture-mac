import Foundation

/// The post-enrichment dispatch seam. `LinkEnrichmentService` calls this the
/// moment a YouTube capture finishes enriching; the implementation only
/// enqueues (a ledger append — the `noteFiled` discipline) and never blocks,
/// because the call happens inside the capture gate.
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
/// pipeline logic — the transcript pipeline itself lives in the user's agentic
/// repo (AGENTS.md, "YouTube URL → Drive Transcript"); the app only points a
/// Claude Code session at it.
enum TranscriptDispatch {
    /// Where the spawned session runs. The feature is a silent no-op when this
    /// directory doesn't exist (the app ships publicly; only machines with the
    /// pipeline repo can dispatch).
    nonisolated static var defaultAgenticRepo: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Repos/NoiseMeldOrg/agentic-os-mirror", isDirectory: true)
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
        """
        Run the "YouTube URL → Drive Transcript" pipeline defined in AGENTS.md on this URL: \(url)

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
