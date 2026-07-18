import Foundation
import OSLog

/// Watches whether the notes folder's git backup is current and publishes a
/// `BackupHealth` on `AppState` (the `DestinationMonitor` shape: a single low-
/// frequency `Task` loop, an internal `tick()` for deterministic tests).
///
/// The check is cheap and read-only. Nothing here mutates the repo or opens a
/// socket — it discovers the repo root, reads local git state through the
/// injected `GitStateReading`, and evaluates staleness. The output folder is read
/// live every tick (it can change), and a volume-absent destination is reported
/// as "can't check," never a failure.
@MainActor
final class BackupHealthMonitor {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "BackupHealthMonitor")

    /// Staleness is measured in hours; a 5-minute poll keeps the Settings line
    /// fresh without spawning `git` often.
    nonisolated static let pollInterval: TimeInterval = 300

    private let appState: AppState
    private let reader: any GitStateReading
    private let destinationGuard: DestinationGuard
    private let hasGitEntry: (URL) -> Bool
    private let threshold: TimeInterval
    private let now: () -> Date

    private var pollTask: Task<Void, Never>?

    init(
        appState: AppState,
        reader: any GitStateReading,
        destinationGuard: DestinationGuard = DestinationGuard(),
        hasGitEntry: @escaping (URL) -> Bool = BackupHealthEvaluator.defaultHasGitEntry,
        threshold: TimeInterval = BackupHealthEvaluator.defaultThreshold,
        now: @escaping () -> Date = { Date() }
    ) {
        self.appState = appState
        self.reader = reader
        self.destinationGuard = destinationGuard
        self.hasGitEntry = hasGitEntry
        self.threshold = threshold
        self.now = now
    }

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            // Immediate first check so the Settings line is never blank, then poll.
            await self?.tick()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                if Task.isCancelled { break }
                await self?.tick()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One check. Internal (not private) so tests drive it deterministically.
    func tick() async {
        let health = await computeHealth()
        if appState.backupHealth != health {
            Self.log.info("backup health → \(String(describing: health), privacy: .public)")
            appState.backupHealth = health
        }
    }

    private func computeHealth() async -> BackupHealth {
        guard let folder = appState.settings.settings.outputFolder else { return .notARepo }
        let normalized = OutputFolderMigrator.normalize(folder)

        // Volume gone → can't read git. Checked before discovery: an unmounted
        // tree can't be walked, and this must never read as "backup failed."
        if destinationGuard.check(normalized) == .volumeAbsent { return .cannotCheck }

        guard let root = BackupHealthEvaluator.discoverRepoRoot(from: normalized, hasGitEntry: hasGitEntry) else {
            return .notARepo
        }

        do {
            let state = try await reader.readState(repoRoot: root)
            return BackupHealthEvaluator.evaluate(state: state, now: now(), threshold: threshold)
        } catch {
            Self.log.error("git read failed: \(String(describing: error), privacy: .public)")
            // Don't flip a known-good display to a false all-clear on transient
            // read trouble — report it as "can't check."
            return .cannotCheck
        }
    }
}
