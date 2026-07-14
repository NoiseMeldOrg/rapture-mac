import Foundation
import OSLog

/// Persisted record of links already enriched, keyed by content identity
/// (`LinkFingerprint`), so a re-captured link points at the existing artifact
/// instead of re-fetching. Sibling of `SpoolFiledLedger`. The stored title is
/// what a re-captured note gets renamed to without a second fetch; the stored
/// artifact path is what its `Media:` link targets.
@MainActor
final class EnrichedLinkLedger {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "EnrichedLinkLedger")

    /// Ninety days, matching the sibling ledgers. A later re-capture re-fetches
    /// (correct: the content may have changed) and collision-walks a fresh artifact.
    nonisolated static let ttl: TimeInterval = 90 * 24 * 60 * 60

    /// Hard ceiling on entries kept in state.json. FIFO eviction.
    nonisolated static let capacity = 500

    private let stateStore: StateStore
    private let clock: @Sendable () -> Date

    init(stateStore: StateStore, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.stateStore = stateStore
        self.clock = clock
    }

    func record(fingerprint: String, artifactRelativePath: String, title: String) {
        let now = clock()
        stateStore.update { state in
            state.enrichedLinkRecords = Self.appendEntry(
                into: state.enrichedLinkRecords,
                fingerprint: fingerprint,
                artifactRelativePath: artifactRelativePath,
                title: title,
                now: now
            )
        }
    }

    func entry(fingerprint: String) -> EnrichedLinkEntry? {
        Self.entry(in: stateStore.state.enrichedLinkRecords, fingerprint: fingerprint, now: clock())
    }

    /// Rewrites `artifactRelativePath` values after an output-folder relocation
    /// collision-renamed artifacts (`OutputFolderMigrator`'s rename report), so
    /// dedup keeps pointing re-captures at the real files.
    func remap(_ renamedNotes: [String: String]) {
        guard !renamedNotes.isEmpty else { return }
        stateStore.update { state in
            state.enrichedLinkRecords = Self.remapped(state.enrichedLinkRecords, renamedNotes: renamedNotes)
        }
    }

    // MARK: - Pure helpers (testable without StateStore)

    nonisolated static func appendEntry(
        into entries: [EnrichedLinkEntry],
        fingerprint: String,
        artifactRelativePath: String,
        title: String,
        now: Date
    ) -> [EnrichedLinkEntry] {
        var kept = entries.filter { $0.fetchedAt.addingTimeInterval(ttl) > now }
        // Refresh by fingerprint: the newest enrichment of a given link wins
        // (used when a recorded artifact was user-deleted and re-fetched).
        kept.removeAll { $0.fingerprint == fingerprint }
        kept.append(EnrichedLinkEntry(
            fingerprint: fingerprint,
            artifactRelativePath: artifactRelativePath,
            title: title,
            fetchedAt: now
        ))
        if kept.count > capacity {
            kept.removeFirst(kept.count - capacity)
        }
        return kept
    }

    nonisolated static func entry(
        in entries: [EnrichedLinkEntry],
        fingerprint: String,
        now: Date
    ) -> EnrichedLinkEntry? {
        entries.last { entry in
            entry.fingerprint == fingerprint
                && entry.fetchedAt.addingTimeInterval(ttl) > now
        }
    }

    nonisolated static func remapped(
        _ entries: [EnrichedLinkEntry],
        renamedNotes: [String: String]
    ) -> [EnrichedLinkEntry] {
        entries.map { entry in
            guard let newPath = renamedNotes[entry.artifactRelativePath] else { return entry }
            return EnrichedLinkEntry(
                fingerprint: entry.fingerprint,
                artifactRelativePath: newPath,
                title: entry.title,
                fetchedAt: entry.fetchedAt
            )
        }
    }
}
