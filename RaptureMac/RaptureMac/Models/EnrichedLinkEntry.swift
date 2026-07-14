import Foundation

/// One enriched link the app has already fetched, keyed by content identity
/// (YouTube video ID / normalized article URL) so a re-captured link points at
/// the existing artifact instead of re-fetching. Persisted in `state.json` via
/// `PersistedState.enrichedLinkRecords`; see `EnrichedLinkLedger`.
struct EnrichedLinkEntry: Codable, Sendable, Equatable {
    /// `"yt:<videoID>"` or `"url:<normalized URL>"` — see `LinkFingerprint`.
    let fingerprint: String
    /// Destination-relative path of the artifact, e.g. `Links/Media/2026-07-13 Title.md`.
    /// Relative so folder relocation doesn't orphan it; remapped on collision renames.
    let artifactRelativePath: String
    /// The sanitized fetched title — what a re-captured note is renamed to
    /// without a second fetch.
    let title: String
    let fetchedAt: Date
}
