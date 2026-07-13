import CryptoKit
import Foundation
import OSLog

/// Persisted record of source `.txt` files already triaged into Markdown notes, so
/// restarts, rescans, and iCloud/sync ghost re-deliveries never double-process.
/// Sibling of `RelayFiledLedger`, keyed by source filename **plus content hash**:
/// timestamped filenames make a same-name re-arrival a re-sync, while the hash keeps
/// a genuinely different same-named hand-drop triagable.
///
/// Each entry records the filed note's destination-relative path. That closes two
/// safety gaps: a ledger hit may drain the source only while the recorded note still
/// exists (re-dropping a source whose note the user deleted re-triages instead of
/// silently destroying their file), and late-arriving relay audio can be placed next
/// to the note it belongs to.
@MainActor
final class TriageLedger {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "TriageLedger")

    /// Ninety days, matching `RelayFiledLedger`: sync services can resurrect
    /// long-deleted items during account reconciliation.
    nonisolated static let ttl: TimeInterval = 90 * 24 * 60 * 60

    /// Hard ceiling on entries kept in state.json. FIFO eviction, same safety-net
    /// rationale as the sibling ledgers.
    nonisolated static let capacity = 500

    private let stateStore: StateStore
    private let clock: @Sendable () -> Date

    init(stateStore: StateStore, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.stateStore = stateStore
        self.clock = clock
    }

    func record(sourceFilename: String, contentHash: String, mdRelativePath: String) {
        let now = clock()
        stateStore.update { state in
            state.triagedRecords = Self.appendEntry(
                into: state.triagedRecords,
                sourceFilename: sourceFilename,
                contentHash: contentHash,
                mdRelativePath: mdRelativePath,
                now: now
            )
        }
    }

    /// Live entry matching both filename and content hash (the double-process guard).
    func entry(sourceFilename: String, contentHash: String) -> TriagedEntry? {
        Self.entry(
            in: stateStore.state.triagedRecords,
            sourceFilename: sourceFilename,
            contentHash: contentHash,
            now: clock()
        )
    }

    /// Live entry by filename alone. Used by orphan-audio recovery, which knows the
    /// paired `.txt` name but not its bytes (the source was drained after filing).
    func entry(sourceFilename: String) -> TriagedEntry? {
        Self.entry(
            in: stateStore.state.triagedRecords,
            sourceFilename: sourceFilename,
            contentHash: nil,
            now: clock()
        )
    }

    /// Rewrites `mdRelativePath` values after an output-folder relocation
    /// collision-renamed notes (`OutputFolderMigrator`'s rename report), so
    /// ghost-draining and orphan-audio placement keep pointing at the real files.
    func remap(_ renamedNotes: [String: String]) {
        guard !renamedNotes.isEmpty else { return }
        stateStore.update { state in
            state.triagedRecords = Self.remapped(state.triagedRecords, renamedNotes: renamedNotes)
        }
    }

    // MARK: - Pure helpers (testable without StateStore)

    nonisolated static func remapped(
        _ entries: [TriagedEntry],
        renamedNotes: [String: String]
    ) -> [TriagedEntry] {
        entries.map { entry in
            guard let newPath = renamedNotes[entry.mdRelativePath] else { return entry }
            return TriagedEntry(
                sourceFilename: entry.sourceFilename,
                contentHash: entry.contentHash,
                mdRelativePath: newPath,
                triagedAt: entry.triagedAt
            )
        }
    }

    nonisolated static func appendEntry(
        into entries: [TriagedEntry],
        sourceFilename: String,
        contentHash: String,
        mdRelativePath: String,
        now: Date
    ) -> [TriagedEntry] {
        var kept = entries.filter { $0.triagedAt.addingTimeInterval(ttl) > now }
        // Refresh by filename: the newest triage of a given source name wins.
        kept.removeAll { $0.sourceFilename == sourceFilename }
        kept.append(TriagedEntry(
            sourceFilename: sourceFilename,
            contentHash: contentHash,
            mdRelativePath: mdRelativePath,
            triagedAt: now
        ))
        if kept.count > capacity {
            kept.removeFirst(kept.count - capacity)
        }
        return kept
    }

    /// `contentHash == nil` matches on filename alone.
    nonisolated static func entry(
        in entries: [TriagedEntry],
        sourceFilename: String,
        contentHash: String?,
        now: Date
    ) -> TriagedEntry? {
        entries.last { entry in
            entry.sourceFilename == sourceFilename
                && entry.triagedAt.addingTimeInterval(ttl) > now
                && (contentHash == nil || entry.contentHash == contentHash)
        }
    }

    /// Canonical content fingerprint for ledger entries: SHA-256 hex of the raw bytes.
    nonisolated static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
