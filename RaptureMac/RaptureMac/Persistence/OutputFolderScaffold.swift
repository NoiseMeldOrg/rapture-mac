import Foundation
import OSLog

/// Optionally seeds a generic starter scaffold into a *fresh* output folder so a
/// brand-new (or recreated-bare) folder comes back usable instead of empty.
///
/// Strictly opt-in (`Settings.seedScaffold`, off by default) and strictly
/// non-destructive: it acts only when the folder is empty **and** has no `CLAUDE.md`,
/// so it can never overwrite or disturb a folder the user already curates. Idempotent —
/// re-running against a folder it already seeded is a no-op (the folder is no longer
/// empty / already has `CLAUDE.md`).
enum OutputFolderScaffold {
    static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "OutputFolderScaffold")

    /// Seed the scaffold when `folder` is eligible. Returns `true` only when files were
    /// actually written. Never throws — a failure is logged and the folder is left as-is.
    @discardableResult
    static func seedIfEligible(folder: URL, fileManager: FileManager = .default) -> Bool {
        guard isEligible(folder, fileManager: fileManager) else { return false }
        do {
            try writeScaffold(into: folder, fileManager: fileManager)
            log.info("Seeded starter scaffold into \(folder.lastPathComponent, privacy: .public)")
            return true
        } catch {
            log.error("Scaffold seeding failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Eligible only when `folder` is an existing, empty directory with no `CLAUDE.md`
    /// (case-insensitive). An empty directory by definition has no `CLAUDE.md`, but the
    /// explicit check guards callers that might relax the emptiness rule later.
    static func isEligible(_ folder: URL, fileManager: FileManager = .default) -> Bool {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return false  // missing or not a readable directory
        }
        if !contents.isEmpty { return false }
        let hasClaudeMd = contents.contains { $0.lastPathComponent.lowercased() == "claude.md" }
        return !hasClaudeMd
    }

    private static func writeScaffold(into folder: URL, fileManager: FileManager) throws {
        // Only the template CLAUDE.md is seeded. The app creates the note
        // subfolders (Notes/, Links/, …) itself as captures file into them.
        let claude = folder.appendingPathComponent("CLAUDE.md")
        try AtomicFile.write(Data(templateClaudeMd.utf8), to: claude)
    }

    /// Generic, user-agnostic starter for an AI assistant pointed at the folder.
    /// Deliberately free of any specific repo paths, client names, or machine
    /// details — those are the user's to fill in. Describes the triaged tree the
    /// app actually produces (the raw-`.txt` contract only exists in raw mode).
    static let templateClaudeMd = """
    # Rapture notes — assistant rules

    Rapture for Mac files every capture here as a Markdown note the moment it
    lands: titled `YYYY-MM-DD <Title>.md`, with a small YAML header (`captured`,
    `source`, `type`, `raw_media`), sorted into subfolders. When an AI assistant
    is pointed at this folder, these instructions tell it how to act on the notes.

    ## The tree

    - **`Notes/`** — voice notes (and anything ambiguous). The default home.
    - **`Links/`** — captured URLs (`type: youtube-link` / `article-link`; the URL
      is in `raw_media`). With enrichment on, fetched transcripts/articles live in
      **`Links/Media/`** and the note links to its artifact under `Media:`.
    - **`Tasks/`, `Ideas/`, `Journal/`** — AI-triage destinations (only when the
      user enabled that tier).
    - Attachments sit in a folder named after their note, linked from the note's
      `Attachments:` footer.

    ## What to do (edit to taste)

    The app already classified, titled, and filed each note — your job is acting
    on the content, not sorting it:

    - `Tasks/` → put actionable items into the task manager of choice.
    - `Links/` → read the note's artifact in `Links/Media/` if present; summarize
      or file the content wherever reference material lives.
    - `Ideas/`, `Journal/` → append to the user's idea list / journal system.
    - Track what you've handled in a log file (e.g. `processed-log.md` at this
      root) instead of moving notes — the folders are the user's organization.

    ## Rules

    - Never delete or rewrite a note; notes are the source of truth. Append to
      your own log/output files instead.
    - A note's verbatim dictation is under `## Raw` when formatting changed the
      body — trust it over the formatted text when they disagree.
    - One note may imply more than one action — handle all of them.
    - When in doubt, do less and ask. These captures can have real side effects.

    > This is a generic starter template seeded by Rapture for Mac. Replace it
    > with your own rules — destinations, client folders, and tool integrations.
    > (If you flipped Settings → Triage to raw mode, captures are `.txt` files at
    > this root instead, and older root-`.txt` workflows apply.)
    """
}
