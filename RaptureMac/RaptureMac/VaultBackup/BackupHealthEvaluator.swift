import Foundation

/// Pure backup-health logic: repo-root discovery and the staleness decision.
/// No I/O — the filesystem probe and `now` are injected — so every branch is
/// table-testable without a real repo (mirrors `DestinationGuard.classify`).
enum BackupHealthEvaluator {
    /// 24 hours — comfortably above any normal backup cadence (obsidian-git
    /// commits every few minutes). A fixed default this milestone; no UI knob.
    static let defaultThreshold: TimeInterval = 24 * 60 * 60

    /// Walk up from `start` until a directory containing a `.git` entry is found;
    /// return that directory (the repo root), or nil if none up to the filesystem
    /// root. The real vault nests the output folder inside the repo, so this must
    /// genuinely walk *up* past the output folder. `hasGitEntry` is injected so
    /// tests exercise a fake tree with no real filesystem.
    static func discoverRepoRoot(from start: URL, hasGitEntry: (URL) -> Bool) -> URL? {
        var dir = start.standardizedFileURL
        while true {
            if hasGitEntry(dir) { return dir }
            let parent = dir.deletingLastPathComponent().standardizedFileURL
            // At the filesystem root, deletingLastPathComponent is a fixed point.
            if parent.path == dir.path { return nil }
            dir = parent
        }
    }

    /// Production `.git` probe: a `.git` directory *or* file (git worktrees use a
    /// `.git` file) marks a repo root.
    static func defaultHasGitEntry(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path)
    }

    /// The staleness decision. "Un-backed-up since" = the earliest of the oldest
    /// unpushed commit and the oldest dirty-file mtime — we age the *actual work*,
    /// never the last-commit clock, so a fresh edit after an idle stretch reads as
    /// fresh (no false alarm). At risk iff that has aged past `threshold`.
    ///
    /// No upstream → the unpushed branch is skipped (only commit/dirty age applies);
    /// a clean no-upstream repo is treated as backed up rather than crying wolf on
    /// what can't be measured.
    static func evaluate(
        state: GitRepoState,
        now: Date,
        threshold: TimeInterval = defaultThreshold
    ) -> BackupHealth {
        let unpushed = state.hasUpstream ? state.unpushedCount : 0

        var anchors: [Date] = []
        if state.dirtyFileCount > 0, let mtime = state.oldestDirtyFileMtime { anchors.append(mtime) }
        if unpushed > 0, let commit = state.oldestUnpushedCommit { anchors.append(commit) }

        guard let since = anchors.min() else {
            // Nothing un-backed-up we can age → healthy.
            return .backedUp(lastCommit: state.lastCommit, pendingChanges: 0)
        }

        if now.timeIntervalSince(since) > threshold {
            return .atRisk(since: since, uncommitted: state.dirtyFileCount, unpushed: unpushed)
        }
        // Un-backed-up work exists but is still inside the grace window.
        return .backedUp(lastCommit: state.lastCommit, pendingChanges: state.dirtyFileCount + unpushed)
    }
}
