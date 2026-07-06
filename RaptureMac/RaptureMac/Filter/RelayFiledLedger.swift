import Foundation
import OSLog

/// Persisted record of relay files already filed into the output folder, so app
/// restarts and iCloud re-syncs never duplicate a note. Sibling to
/// `ContentDedupCache`, but keyed by relay filename: the iPhone overwrites the same
/// relay name on a re-send, so the name is the dedup identity.
///
/// The ledger closes the crash window between "note filed" and "relay copy
/// deleted": the processor records here (persisted synchronously via `StateStore`)
/// before deleting the relay copy, so a crash in between resumes as "delete only,
/// never re-file". Deleting the relay copy is what normally stops re-processing;
/// the ledger is the belt-and-suspenders guard.
@MainActor
final class RelayFiledLedger {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "RelayFiledLedger")

    /// Ninety days. iCloud can resurrect long-deleted items during account sync
    /// reconciliation; filenames are timestamped so a true same-name re-arrival is a
    /// re-sync, not a new note. Storage cost at the cap is trivial.
    nonisolated static let ttl: TimeInterval = 90 * 24 * 60 * 60

    /// Hard ceiling on entries kept in state.json. FIFO eviction; same safety-net
    /// rationale as `ContentDedupCache.capacity`.
    nonisolated static let capacity = 500

    private let stateStore: StateStore
    private let clock: @Sendable () -> Date

    init(stateStore: StateStore, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.stateStore = stateStore
        self.clock = clock
    }

    func record(relayFilename: String) {
        let now = clock()
        stateStore.update { state in
            state.relayFiledRecords = Self.appendEntry(
                into: state.relayFiledRecords,
                relayFilename: relayFilename,
                now: now
            )
        }
    }

    func contains(relayFilename: String) -> Bool {
        Self.matches(
            entries: stateStore.state.relayFiledRecords,
            relayFilename: relayFilename,
            now: clock()
        )
    }

    // MARK: - Pure helpers (testable without StateStore)

    nonisolated static func appendEntry(
        into entries: [RelayFiledEntry],
        relayFilename: String,
        now: Date
    ) -> [RelayFiledEntry] {
        var kept = entries.filter { $0.filedAt.addingTimeInterval(ttl) > now }
        // Refresh an existing key instead of appending a duplicate.
        kept.removeAll { $0.relayFilename == relayFilename }
        kept.append(RelayFiledEntry(relayFilename: relayFilename, filedAt: now))
        if kept.count > capacity {
            kept.removeFirst(kept.count - capacity)
        }
        return kept
    }

    nonisolated static func matches(
        entries: [RelayFiledEntry],
        relayFilename: String,
        now: Date
    ) -> Bool {
        entries.contains { entry in
            entry.relayFilename == relayFilename
                && entry.filedAt.addingTimeInterval(ttl) > now
        }
    }
}
