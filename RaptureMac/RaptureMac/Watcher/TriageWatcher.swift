import Foundation
import OSLog

/// Third arrival path into the destination: watches the output-folder *root* for
/// external `.txt` captures — hand-drops, other-device sync deliveries, and the
/// pre-triage backlog — and yields settled files ready to triage. App-written
/// captures never pass through here (compose-direct writes them as final `.md` in
/// one step), so in normal live use this watcher is quiet.
///
/// Same poll-plus-pure-planner shape as `RelayWatcher`: detached utility task, full
/// snapshot per tick, pure planning helpers, an `AsyncStream` consumed on the main
/// actor. Polling self-heals across output-folder relocation because the folder is
/// re-read from settings every tick — no fd lifecycle, no re-arm hook. Event-driven
/// watching (FSEvents/DispatchSource) was considered and deliberately not adopted;
/// see the milestone log for the trade-off.
@MainActor
final class TriageWatcher {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "TriageWatcher")

    /// Matches `RelayWatcher.pollInterval`: external arrivals ride sync latency,
    /// so 5s feels immediate while keeping the scan cheap.
    nonisolated static let pollInterval: TimeInterval = 5

    /// A file is settled when it has been visible at least this long **and** its
    /// size matched across two consecutive snapshots. Sync engines rename completed
    /// files into place, so this is belt-and-suspenders against partial writes.
    /// mtime is deliberately not part of the rule: synced files arrive with
    /// preserved (old) modification dates and would look instantly settled.
    nonisolated static let settleAge: TimeInterval = 5

    private var pollTask: Task<Void, Never>?

    /// Starts the polling loop. Both providers are read every tick, so a mode flip
    /// or folder relocation needs no watcher restart. `onStatus` receives
    /// deduplicated status changes.
    func batches(
        folderProvider: @escaping @Sendable () async -> URL?,
        modeProvider: @escaping @Sendable () async -> TriageMode,
        onStatus: @escaping @Sendable (TriageStatus) async -> Void
    ) -> AsyncStream<TriageScanBatch> {
        // Newest-only buffering: every batch is a full re-derivable snapshot, so a
        // stale queued snapshot is worthless once a newer one exists.
        let (stream, continuation) = AsyncStream<TriageScanBatch>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pollTask = Task.detached(priority: .utility) {
            var firstSeen: [String: Date] = [:]
            var previousSizes: [String: Int] = [:]
            var watchedFolderPath: String?
            var lastPosted: TriageStatus?
            var loggedNudgeFailures: Set<String> = []

            func post(_ status: TriageStatus) async {
                guard status != lastPosted else { return }
                lastPosted = status
                await onStatus(status)
            }

            while !Task.isCancelled {
                if await modeProvider() == .raw {
                    firstSeen = [:]
                    previousSizes = [:]
                    await post(.off)
                } else if let folder = await folderProvider() {
                    // A relocated folder starts with fresh settle state: a same-named
                    // file in the new root must earn its own two sightings, never
                    // inherit another file's aging/size history. Nudge-failure logging
                    // resets too, so a placeholder that migrated with the folder gets
                    // its coordinated-read fallback retried in the new location.
                    if watchedFolderPath != folder.path {
                        watchedFolderPath = folder.path
                        firstSeen = [:]
                        previousSizes = [:]
                        loggedNudgeFailures = []
                    }
                    let entries = Self.scanEntries(in: folder)
                    let plan = Self.plan(
                        entries: entries,
                        firstSeen: firstSeen,
                        previousSizes: previousSizes,
                        now: Date()
                    )
                    firstSeen = plan.newFirstSeen
                    previousSizes = plan.newSizes
                    for name in plan.placeholdersToNudge {
                        RelayWatcher.nudgeDownload(
                            of: folder.appendingPathComponent(name),
                            loggedFailures: &loggedNudgeFailures
                        )
                    }
                    if plan.placeholdersToNudge.isEmpty {
                        await post(.watching)
                    } else {
                        await post(.waitingForDownload(count: plan.placeholdersToNudge.count))
                    }
                    if !plan.ready.isEmpty {
                        continuation.yield(TriageScanBatch(candidates: plan.ready.map { name in
                            TriageCandidate(filename: name)
                        }))
                    }
                } else {
                    firstSeen = [:]
                    previousSizes = [:]
                    await post(.waitingForFolder)
                }
                try? await Task.sleep(for: .seconds(Self.pollInterval))
            }
            continuation.finish()
        }
        return stream
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Snapshot

    struct Entry: Equatable, Sendable {
        let name: String
        let isDirectory: Bool
        let size: Int
        let modifiedAt: Date?
    }

    /// One filesystem snapshot of the root: names plus the attributes the planner
    /// needs. Runs on the detached poll task, never the main actor.
    nonisolated static func scanEntries(in folder: URL) -> [Entry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return [] }
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: keys)
            return Entry(
                name: url.lastPathComponent,
                isDirectory: values?.isDirectory ?? false,
                size: values?.fileSize ?? 0,
                modifiedAt: values?.contentModificationDate
            )
        }
    }

    // MARK: - Pure planner

    struct TriageScanPlan: Equatable, Sendable {
        var ready: [String]
        var placeholdersToNudge: [String]
        var newFirstSeen: [String: Date]
        var newSizes: [String: Int]
    }

    /// Classifies one root snapshot into work. Pure: all timing decisions flow from
    /// the injected maps and `now`. Root-only, files-only, `.txt`-only — triage
    /// outputs (`.md`, subfolders, attachment folders) can never be re-selected.
    nonisolated static func plan(
        entries: [Entry],
        firstSeen: [String: Date],
        previousSizes: [String: Int],
        now: Date
    ) -> TriageScanPlan {
        var placeholders: [String] = []
        var candidates: [Entry] = []

        for entry in entries where !entry.isDirectory {
            if let target = RelayWatcher.placeholderTarget(entry.name) {
                // Only undownloaded *.txt captures are our business to nudge.
                if target.lowercased().hasSuffix(".txt") {
                    placeholders.append(entry.name)
                }
                continue
            }
            if entry.name.hasPrefix(".") { continue }  // hidden + atomic-write temp files
            guard entry.name.lowercased().hasSuffix(".txt") else { continue }
            candidates.append(entry)
        }

        var newFirstSeen: [String: Date] = [:]
        var newSizes: [String: Int] = [:]
        var ready: [(name: String, sortKey: Date)] = []

        for entry in candidates {
            let seen = firstSeen[entry.name] ?? now
            newFirstSeen[entry.name] = seen
            newSizes[entry.name] = entry.size
            let settled = now.timeIntervalSince(seen) >= settleAge
                && previousSizes[entry.name] == entry.size
            if settled {
                // Oldest-first: contract filenames carry their capture instant;
                // freeform files fall back to mtime, then first-sighting.
                let sortKey = RelayWatcher.parseRelayTimestamp(entry.name)
                    ?? entry.modifiedAt
                    ?? seen
                ready.append((entry.name, sortKey))
            }
        }

        return TriageScanPlan(
            ready: ready
                .sorted { ($0.sortKey, $0.name) < ($1.sortKey, $1.name) }
                .map(\.name),
            placeholdersToNudge: placeholders.sorted(),
            newFirstSeen: newFirstSeen,
            newSizes: newSizes
        )
    }
}
