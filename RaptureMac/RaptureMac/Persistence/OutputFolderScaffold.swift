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
        try fileManager.createDirectory(
            at: folder.appendingPathComponent("processed", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: folder.appendingPathComponent("in-progress", isDirectory: true),
            withIntermediateDirectories: true
        )
        let claude = folder.appendingPathComponent("CLAUDE.md")
        try AtomicFile.write(Data(templateClaudeMd.utf8), to: claude)
    }

    /// Generic, user-agnostic routing-rules template. Deliberately free of any specific
    /// repo paths, client names, or machine details — those are the user's to fill in.
    static let templateClaudeMd = """
    # Rapture notes — triage rules

    This folder collects Siri-dictated iMessages captured by Rapture for Mac, one `.txt`
    file per note (filenames are ISO 8601 UTC timestamps). When an AI assistant is pointed
    at this folder, these instructions tell it how to process each note.

    ## What you're processing

    `.txt` files in the root of this folder. Each is a short spoken thought. Read each one,
    decide what it is, act on it, then move it into `processed/YYYY-MM/`.

    ## Folders

    - **root** — pending, unprocessed notes.
    - **`in-progress/`** — notes you're mid-way through actioning (e.g. waiting on an
      external step). Move back to root or on to `processed/` when resolved.
    - **`processed/`** — archive of handled notes, grouped by month (`processed/2026-06/`).

    ## Suggested routing (edit to taste)

    - A reminder or task → your task manager, then archive the note.
    - A link or article → save/extract it, then archive.
    - A journal entry or idea → append to your notes/journal, then archive.
    - Anything ambiguous → leave in root and flag it rather than guessing.

    ## Rules

    - Never delete a note's content; only move the file.
    - One note may imply more than one action — handle all of them before archiving.
    - When in doubt, do less and ask. These captures can have real side effects.

    > This is a generic starter template seeded by Rapture for Mac. Replace it with your
    > own routing rules — destinations, client folders, and tool integrations.
    """
}
