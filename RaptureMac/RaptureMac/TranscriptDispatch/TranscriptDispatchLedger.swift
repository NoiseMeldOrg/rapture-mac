import Foundation
import OSLog

/// Persisted record of YouTube captures handed to the transcript pipeline,
/// keyed by content identity (`LinkFingerprint`), so a video is never
/// dispatched twice — across restarts and re-captures. Fourth sibling of
/// `SpoolFiledLedger` / `EnrichedLinkLedger` / `HandoffLedger`.
@MainActor
final class TranscriptDispatchLedger {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "TranscriptDispatchLedger")

    /// Ninety days, matching the sibling ledgers. A video re-captured later
    /// re-dispatches — matching enrichment's own re-fetch semantics.
    nonisolated static let ttl: TimeInterval = 90 * 24 * 60 * 60

    /// Hard ceiling on entries kept in state.json. FIFO eviction.
    nonisolated static let capacity = 500

    /// Already processed by hand before this feature existed; seeded as `done`
    /// on first start so it is never dispatched again.
    nonisolated static let seedFingerprint = "yt:JGB-D1xd400"

    private let stateStore: StateStore
    private let clock: @Sendable () -> Date

    init(stateStore: StateStore, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.stateStore = stateStore
        self.clock = clock
    }

    var records: [TranscriptDispatchEntry] {
        stateStore.state.transcriptDispatchRecords
    }

    func entry(fingerprint: String) -> TranscriptDispatchEntry? {
        Self.entry(in: records, fingerprint: fingerprint, now: clock())
    }

    func append(_ entry: TranscriptDispatchEntry) {
        let now = clock()
        stateStore.update { state in
            state.transcriptDispatchRecords = Self.appendEntry(
                into: state.transcriptDispatchRecords, entry: entry, now: now)
        }
    }

    /// Mutates the entry for `fingerprint` in place (status transitions). No-op
    /// when the fingerprint is absent.
    func update(fingerprint: String, _ mutate: (inout TranscriptDispatchEntry) -> Void) {
        stateStore.update { state in
            guard let index = state.transcriptDispatchRecords.lastIndex(where: { $0.fingerprint == fingerprint }) else { return }
            mutate(&state.transcriptDispatchRecords[index])
        }
    }

    /// All `failed` entries back to `pending` (attempts kept, error cleared) —
    /// the Settings "Retry failed" button.
    func retryFailed() {
        stateStore.update { state in
            state.transcriptDispatchRecords = Self.failedResetToPending(state.transcriptDispatchRecords)
        }
    }

    /// Rewrites `noteRelativePath` values after an output-folder relocation
    /// collision-renamed notes (`OutputFolderMigrator`'s rename report), so
    /// spawn-time resolution keeps pointing at the real files.
    func remap(_ renamedNotes: [String: String]) {
        guard !renamedNotes.isEmpty else { return }
        stateStore.update { state in
            state.transcriptDispatchRecords = Self.remapped(state.transcriptDispatchRecords, renamedNotes: renamedNotes)
        }
    }

    /// One-time seed: records `seedFingerprint` as `done` iff no entry for it
    /// exists (any status counts — never clobber real history). Idempotent by
    /// the presence check.
    func seedIfNeeded(now: Date) {
        guard !records.contains(where: { $0.fingerprint == Self.seedFingerprint }) else { return }
        append(TranscriptDispatchEntry(
            fingerprint: Self.seedFingerprint,
            url: "",
            noteRelativePath: "",
            status: .done,
            createdAt: now
        ))
    }

    // MARK: - Pure helpers (testable without StateStore)

    nonisolated static func appendEntry(
        into entries: [TranscriptDispatchEntry],
        entry: TranscriptDispatchEntry,
        now: Date
    ) -> [TranscriptDispatchEntry] {
        var kept = entries.filter { $0.createdAt.addingTimeInterval(ttl) > now }
        // Refresh by fingerprint: the newest capture of a given video wins.
        kept.removeAll { $0.fingerprint == entry.fingerprint }
        kept.append(entry)
        if kept.count > capacity {
            kept.removeFirst(kept.count - capacity)
        }
        return kept
    }

    nonisolated static func entry(
        in entries: [TranscriptDispatchEntry],
        fingerprint: String,
        now: Date
    ) -> TranscriptDispatchEntry? {
        entries.last { entry in
            entry.fingerprint == fingerprint
                && entry.createdAt.addingTimeInterval(ttl) > now
        }
    }

    nonisolated static func failedResetToPending(_ entries: [TranscriptDispatchEntry]) -> [TranscriptDispatchEntry] {
        entries.map { entry in
            guard entry.status == .failed else { return entry }
            var reset = entry
            reset.status = .pending
            reset.lastError = nil
            return reset
        }
    }

    nonisolated static func remapped(
        _ entries: [TranscriptDispatchEntry],
        renamedNotes: [String: String]
    ) -> [TranscriptDispatchEntry] {
        entries.map { entry in
            guard let newPath = renamedNotes[entry.noteRelativePath] else { return entry }
            var moved = entry
            moved.noteRelativePath = newPath
            return moved
        }
    }
}
