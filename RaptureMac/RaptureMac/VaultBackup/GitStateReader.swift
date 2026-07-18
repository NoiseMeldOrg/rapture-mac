import Foundation

/// Raw, read-only facts about a git repo's backup state — everything
/// `BackupHealthEvaluator` needs, gathered by a `GitStateReading`. Nothing here
/// is derived or persisted; each field maps to a single read-only `git`/`stat`.
struct GitRepoState: Equatable, Sendable {
    /// HEAD has a configured upstream (`@{u}` resolves). When false, "unpushed"
    /// is undefined and only uncommitted-work age applies.
    var hasUpstream: Bool
    /// Number of dirty working-tree/index entries (`git status --porcelain`).
    var dirtyFileCount: Int
    /// Commits on HEAD not on the upstream tracking ref (0 when no upstream).
    var unpushedCount: Int
    /// Commit date of the oldest unpushed commit (nil when none / no upstream).
    var oldestUnpushedCommit: Date?
    /// mtime of the oldest dirty working-tree file (nil when clean, or when every
    /// dirty entry is a deletion with no stat-able mtime).
    var oldestDirtyFileMtime: Date?
    /// Date of HEAD's last commit (nil for an empty repo).
    var lastCommit: Date?

    var isDirty: Bool { dirtyFileCount > 0 }
}

/// The git-state read seam. Tests inject `FakeGitStateReader`; the app uses
/// `SystemGitStateReader`.
///
/// **Read-only, no network, no repo mutation.** The implementation runs only
/// `git rev-parse` / `status` / `rev-list` / `log` and `stat` — never `add`,
/// `commit`, `push`, `fetch`, or `pull`, and holds no credential. Reading local
/// refs needs no socket, so this feature adds zero networking (PRIVACY unchanged).
///
/// `@MainActor` mirrors `LinkFetching`: the front-guard reads the MainActor-
/// isolated `isRunningXCTests`, and the real reader hops to `Task.detached` for
/// the blocking subprocess so the main actor is never held.
@MainActor
protocol GitStateReading: AnyObject, Sendable {
    func readState(repoRoot: URL) async throws -> GitRepoState
}

/// Read failures. `.unavailableUnderTests` is the XCTest front-guard result
/// (the hosted suite never spawns real `git`), mirroring `LinkFetchError.unavailable`.
enum GitReadError: Error, Equatable, Sendable {
    case unavailableUnderTests
    case gitFailed(exitCode: Int32, stderr: String)
}
