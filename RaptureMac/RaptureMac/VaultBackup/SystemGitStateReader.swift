import Foundation
import OSLog

/// The production `GitStateReading`: reads a repo's backup state by running
/// read-only `git` subcommands via `Foundation.Process` (the `AppleScriptSender`
/// pattern — explicit executable path, controlled environment, no login shell).
///
/// **It never mutates the repo or touches the network.** Only `rev-parse`,
/// `status --porcelain`, `rev-list --count`, and `log --format=%ct` run, plus a
/// `stat` of dirty files for their mtimes. `GIT_OPTIONAL_LOCKS=0` keeps even
/// `status` from taking the index lock, and `GIT_TERMINAL_PROMPT=0` guarantees it
/// can never block on a credential prompt. Front-guarded on XCTest so the hosted
/// suite spawns no real `git`.
@MainActor
final class SystemGitStateReader: GitStateReading {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "GitStateReader")
    nonisolated static let gitPath = "/usr/bin/git"

    func readState(repoRoot: URL) async throws -> GitRepoState {
        guard !ProcessInfo.processInfo.isRunningXCTests else { throw GitReadError.unavailableUnderTests }
        // The blocking subprocess work runs off the main actor.
        return try await Task.detached(priority: .utility) {
            try Self.read(repoRoot: repoRoot)
        }.value
    }

    // MARK: - Read (off the main actor)

    nonisolated private static func read(repoRoot: URL) throws -> GitRepoState {
        // Upstream? `@{u}` resolves only when HEAD has a tracking branch.
        let upstream = try runGit(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: repoRoot)
        let hasUpstream = upstream.exitCode == 0 && !upstream.stdout.trimmed.isEmpty

        // Dirty entries (+ oldest mtime). `-z`: NUL-terminated, unquoted paths.
        let status = try runGit(["status", "--porcelain", "-z"], in: repoRoot)
        guard status.exitCode == 0 else {
            throw GitReadError.gitFailed(exitCode: status.exitCode, stderr: status.stderr)
        }
        let dirtyPaths = parsePorcelainZ(status.stdout)
        let oldestDirtyMtime = oldestMtime(of: dirtyPaths, repoRoot: repoRoot)

        // Unpushed commits (only meaningful with an upstream).
        var unpushedCount = 0
        var oldestUnpushed: Date?
        if hasUpstream {
            if let count = try? runGit(["rev-list", "--count", "@{u}..HEAD"], in: repoRoot),
               count.exitCode == 0 {
                unpushedCount = Int(count.stdout.trimmed) ?? 0
            }
            if unpushedCount > 0,
               let log = try? runGit(["log", "--format=%ct", "@{u}..HEAD"], in: repoRoot),
               log.exitCode == 0 {
                oldestUnpushed = oldestEpoch(log.stdout)
            }
        }

        // Last commit time (nil for an empty repo).
        var lastCommit: Date?
        if let head = try? runGit(["log", "-1", "--format=%ct", "HEAD"], in: repoRoot),
           head.exitCode == 0, let epoch = TimeInterval(head.stdout.trimmed) {
            lastCommit = Date(timeIntervalSince1970: epoch)
        }

        return GitRepoState(
            hasUpstream: hasUpstream,
            dirtyFileCount: dirtyPaths.count,
            unpushedCount: unpushedCount,
            oldestUnpushedCommit: oldestUnpushed,
            oldestDirtyFileMtime: oldestDirtyMtime,
            lastCommit: lastCommit
        )
    }

    // MARK: - Subprocess

    private struct GitOutput { let exitCode: Int32; let stdout: String; let stderr: String }

    nonisolated private static func runGit(_ args: [String], in repoRoot: URL) throws -> GitOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = ["-C", repoRoot.path] + args
        // Tight, explicit environment: no networked credential helpers, no index
        // lock, no interactive prompt. Nothing here can mutate the repo.
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0"
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = Pipe()

        try process.run()
        // Read stdout to EOF before waiting so a large `status` (hundreds of dirty
        // files) can't fill the pipe buffer and deadlock the child.
        let outData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        let errData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()

        return GitOutput(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    // MARK: - Parsing helpers

    /// Paths from `git status --porcelain -z`. Each entry is `XY<space>PATH`,
    /// entries NUL-separated. A rename/copy (`R`/`C`) is followed by its origin
    /// path as a separate NUL token — we keep the new path (which exists) and skip
    /// the origin.
    nonisolated static func parsePorcelainZ(_ output: String) -> [String] {
        let entries = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var paths: [String] = []
        var i = 0
        while i < entries.count {
            let entry = entries[i]
            guard entry.count >= 4 else { i += 1; continue }
            let statusXY = entry.prefix(2)
            let path = String(entry.dropFirst(3)) // skip "XY "
            paths.append(path)
            if statusXY.contains("R") || statusXY.contains("C") {
                i += 2 // skip the origin-path token
            } else {
                i += 1
            }
        }
        return paths
    }

    /// Oldest mtime among the dirty files; deletions (no stat-able mtime) are
    /// skipped. nil when nothing stat-able remains.
    nonisolated static func oldestMtime(of relativePaths: [String], repoRoot: URL) -> Date? {
        let fm = FileManager.default
        var oldest: Date?
        for rel in relativePaths {
            let full = repoRoot.appendingPathComponent(rel)
            guard let attrs = try? fm.attributesOfItem(atPath: full.path),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            if oldest == nil || mtime < oldest! { oldest = mtime }
        }
        return oldest
    }

    /// Oldest commit time from a newline list of epoch seconds (`log --format=%ct`).
    nonisolated static func oldestEpoch(_ output: String) -> Date? {
        let epochs = output
            .split(whereSeparator: \.isNewline)
            .compactMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
        guard let min = epochs.min() else { return nil }
        return Date(timeIntervalSince1970: min)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
