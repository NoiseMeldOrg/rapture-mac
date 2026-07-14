import Foundation
import OSLog

/// Persisted record of Reminders/Calendar items the handoff engine created,
/// keyed by content fingerprint (kind + normalized title + due/start key), so a
/// re-dictated duplicate never double-creates — "a duplicate event is a
/// real-world side effect" (the rulebook's dedup rule). Consulted at every
/// filing seam, including the spool-flush path, which also makes it the second
/// guard for the crash window between "item created" and the seam's own ledger
/// record.
///
/// Same shape as `RelayFiledLedger`: TTL + capacity + pure static helpers,
/// persisted synchronously in state.json. One wrinkle: **dateless** reminders
/// dedup on a 48-hour window instead of the full TTL — the systemic double-fire
/// risks (crash resume, spool flush, iCloud re-sync, same-day re-dictation) all
/// land within hours, while a genuinely repeated chore re-dictated next week
/// must create again. Dated items keep the full TTL: identical title +
/// identical timestamp days later is definitionally the same real-world item.
@MainActor
final class HandoffLedger {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "HandoffLedger")

    nonisolated static let ttl: TimeInterval = 90 * 24 * 60 * 60
    nonisolated static let datelessWindow: TimeInterval = 48 * 60 * 60
    nonisolated static let capacity = 500

    /// The dateKey for items with no due/start date; carries the shorter window.
    nonisolated static let datelessDateKey = "none"

    private let stateStore: StateStore
    private let clock: @Sendable () -> Date

    init(stateStore: StateStore, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.stateStore = stateStore
        self.clock = clock
    }

    func record(fingerprint: String) {
        let now = clock()
        stateStore.update { state in
            state.handoffRecords = Self.appendEntry(
                into: state.handoffRecords,
                fingerprint: fingerprint,
                now: now
            )
        }
    }

    func contains(fingerprint: String) -> Bool {
        Self.matches(
            entries: stateStore.state.handoffRecords,
            fingerprint: fingerprint,
            now: clock()
        )
    }

    // MARK: - Fingerprint composition (pure)

    nonisolated static func fingerprint(kind: HandoffKind, title: String, dateKey: String) -> String {
        "\(kind.rawValue)|\(normalizeTitle(title))|\(dateKey)"
    }

    /// Second fingerprint (M4): keyed by the verbatim source *clause* instead of
    /// the item title. AI smart titles vary across re-dictations of the same
    /// utterance, but the clause text is stable — recording and checking BOTH
    /// fingerprints on every creation blocks deterministic↔AI double-creates in
    /// either direction. The `clause|` marker segment keeps the namespace
    /// disjoint from title fingerprints; the dateKey stays terminal so
    /// `window(forFingerprint:)`'s dateless rule applies unchanged.
    nonisolated static func clauseFingerprint(kind: HandoffKind, clause: String, dateKey: String) -> String {
        "\(kind.rawValue)|clause|\(normalizeTitle(clause))|\(dateKey)"
    }

    /// Lowercased, whitespace-collapsed, trailing punctuation stripped — the
    /// same utterance re-dictated with different capitalization or a trailing
    /// period must fingerprint identically.
    nonisolated static func normalizeTitle(_ title: String) -> String {
        var normalized = title
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        while let last = normalized.last, ".,;:!?".contains(last) {
            normalized.removeLast()
        }
        return normalized.trimmingCharacters(in: .whitespaces)
    }

    /// Timed → full ISO 8601 UTC instant; date-only → the local calendar day;
    /// nil → `datelessDateKey` (48-hour window).
    nonisolated static func dateKey(for resolved: HandoffDateParser.Resolved?, timeZone: TimeZone) -> String {
        guard let resolved else { return datelessDateKey }
        if resolved.hasTime {
            return dateKey(forEventStart: resolved.date)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: resolved.date)
    }

    nonisolated static func dateKey(forEventStart start: Date) -> String {
        // Fresh per call (house idiom — the formatter types aren't Sendable).
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: start)
    }

    // MARK: - Pure helpers (testable without StateStore)

    /// Dateless fingerprints live on the short window; everything else on the TTL.
    nonisolated static func window(forFingerprint fingerprint: String) -> TimeInterval {
        fingerprint.hasSuffix("|\(datelessDateKey)") ? datelessWindow : ttl
    }

    nonisolated static func appendEntry(
        into entries: [HandoffEntry],
        fingerprint: String,
        now: Date
    ) -> [HandoffEntry] {
        var kept = entries.filter { $0.createdAt.addingTimeInterval(window(forFingerprint: $0.fingerprint)) > now }
        // Refresh an existing key instead of appending a duplicate.
        kept.removeAll { $0.fingerprint == fingerprint }
        kept.append(HandoffEntry(fingerprint: fingerprint, createdAt: now))
        if kept.count > capacity {
            kept.removeFirst(kept.count - capacity)
        }
        return kept
    }

    nonisolated static func matches(
        entries: [HandoffEntry],
        fingerprint: String,
        now: Date
    ) -> Bool {
        entries.contains { entry in
            entry.fingerprint == fingerprint
                && entry.createdAt.addingTimeInterval(window(forFingerprint: entry.fingerprint)) > now
        }
    }
}
