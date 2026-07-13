import Foundation
import OSLog

/// Persisted record of spool items already flushed into the destination, closing
/// the crash window between "note filed" and "spool item removed": the flush
/// records here (persisted synchronously via `StateStore`) before deleting the
/// spool item, so a crash in between resumes as "delete only, never re-file".
/// Sibling of `RelayFiledLedger`, keyed by the spool item's directory name —
/// unique forever because its seq component is monotonic and never reused.
@MainActor
final class SpoolFiledLedger {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "SpoolFiledLedger")

    /// Same rationale as `RelayFiledLedger.ttl`: the guarded window only needs to
    /// outlive any plausible resume delay; storage at the cap is trivial.
    nonisolated static let ttl: TimeInterval = 90 * 24 * 60 * 60

    /// Hard ceiling on entries kept in state.json. FIFO eviction.
    nonisolated static let capacity = 500

    private let stateStore: StateStore
    private let clock: @Sendable () -> Date

    init(stateStore: StateStore, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.stateStore = stateStore
        self.clock = clock
    }

    func record(itemName: String) {
        let now = clock()
        stateStore.update { state in
            state.spoolFiledRecords = Self.appendEntry(
                into: state.spoolFiledRecords,
                itemName: itemName,
                now: now
            )
        }
    }

    func contains(itemName: String) -> Bool {
        Self.matches(
            entries: stateStore.state.spoolFiledRecords,
            itemName: itemName,
            now: clock()
        )
    }

    // MARK: - Pure helpers (testable without StateStore)

    nonisolated static func appendEntry(
        into entries: [SpoolFiledEntry],
        itemName: String,
        now: Date
    ) -> [SpoolFiledEntry] {
        var kept = entries.filter { $0.filedAt.addingTimeInterval(ttl) > now }
        kept.removeAll { $0.itemName == itemName }
        kept.append(SpoolFiledEntry(itemName: itemName, filedAt: now))
        if kept.count > capacity {
            kept.removeFirst(kept.count - capacity)
        }
        return kept
    }

    nonisolated static func matches(
        entries: [SpoolFiledEntry],
        itemName: String,
        now: Date
    ) -> Bool {
        entries.contains { entry in
            entry.itemName == itemName
                && entry.filedAt.addingTimeInterval(ttl) > now
        }
    }
}
