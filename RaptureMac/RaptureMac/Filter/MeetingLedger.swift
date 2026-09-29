import CryptoKit
import Foundation
import OSLog

/// Persisted record of filed meetings, keyed by the iOS recording id, so a
/// meeting's transcript and every later summary land in ONE note. Sibling of
/// `RelayFiledLedger`, but keyed by meeting id instead of relay filename: the
/// summary part usually carries a new title (so a new relay filename), and a
/// re-made summary can reuse the old name, so the filename is not the
/// identity here.
@MainActor
final class MeetingLedger {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "MeetingLedger")

    /// One year. A summary can come days after its transcript, and a meeting
    /// the ledger forgot files its next summary as a new note — so this errs
    /// long. Entries are small.
    nonisolated static let ttl: TimeInterval = 365 * 24 * 60 * 60

    /// Hard ceiling on entries kept in state.json. FIFO eviction, same
    /// safety-net rationale as the sibling ledgers.
    nonisolated static let capacity = 500

    /// Applied-summary hashes kept per meeting. Only needs to span how many
    /// times a user plausibly re-makes one summary.
    nonisolated static let summaryHashCapacity = 20

    private let stateStore: StateStore
    private let clock: @Sendable () -> Date

    init(stateStore: StateStore, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.stateStore = stateStore
        self.clock = clock
    }

    func entry(meetingId: String) -> MeetingEntry? {
        Self.live(stateStore.state.meetingRecords, now: clock())
            .first { $0.meetingId == meetingId }
    }

    /// The meeting a relay filename belonged to (any part). Orphan relay audio
    /// knows only its paired `.txt` name.
    func entry(relayFilename: String) -> MeetingEntry? {
        Self.live(stateStore.state.meetingRecords, now: clock())
            .first { $0.relayFilenames.contains(relayFilename) }
    }

    func upsert(_ entry: MeetingEntry) {
        let now = clock()
        stateStore.update { state in
            state.meetingRecords = Self.upserting(entry, into: state.meetingRecords, now: now)
        }
    }

    /// Relocation collision renames: keep recorded note paths pointing at the
    /// real files (same contract as `TriageLedger.remap`).
    func remap(_ renamedNotes: [String: String]) {
        guard !renamedNotes.isEmpty else { return }
        stateStore.update { state in
            state.meetingRecords = state.meetingRecords.map { entry in
                guard let newPath = renamedNotes[entry.noteRelativePath] else { return entry }
                var updated = entry
                updated.noteRelativePath = newPath
                return updated
            }
        }
    }

    // MARK: - Pure helpers (testable without StateStore)

    nonisolated static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func live(_ entries: [MeetingEntry], now: Date) -> [MeetingEntry] {
        entries.filter { $0.updatedAt.addingTimeInterval(ttl) > now }
    }

    /// Replaces any entry for the same id (the newest write moves to the back,
    /// so FIFO eviction drops the least recently touched meeting first).
    nonisolated static func upserting(_ entry: MeetingEntry, into entries: [MeetingEntry], now: Date) -> [MeetingEntry] {
        var kept = live(entries, now: now)
        kept.removeAll { $0.meetingId == entry.meetingId }
        var stored = entry
        stored.updatedAt = now
        if stored.appliedSummaryHashes.count > summaryHashCapacity {
            stored.appliedSummaryHashes.removeFirst(stored.appliedSummaryHashes.count - summaryHashCapacity)
        }
        kept.append(stored)
        if kept.count > capacity {
            kept.removeFirst(kept.count - capacity)
        }
        return kept
    }
}
