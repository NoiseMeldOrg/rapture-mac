import Foundation

/// One YouTube capture's transcript-dispatch record, keyed by content identity
/// (`LinkFingerprint`, `"yt:<videoID>"`) so a video is never dispatched twice —
/// across restarts, iCloud replays, and enrichment dedups. Persisted in
/// `state.json` via `PersistedState.transcriptDispatchRecords`; see
/// `TranscriptDispatchLedger`.
struct TranscriptDispatchEntry: Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable {
        case pending
        case dispatched
        case done
        case failed
    }

    /// `"yt:<videoID>"` — see `LinkFingerprint`.
    let fingerprint: String
    /// The captured URL, verbatim — what the spawned session's prompt carries.
    let url: String
    /// Destination-relative path of the source note (post-rename). Relative so
    /// folder relocation doesn't orphan it; resolved against the current output
    /// folder at spawn time and remapped on collision renames.
    var noteRelativePath: String
    var status: Status
    /// FIFO key and TTL base.
    let createdAt: Date
    var dispatchedAt: Date?
    var attempts: Int
    var lastError: String?

    init(
        fingerprint: String,
        url: String,
        noteRelativePath: String,
        status: Status,
        createdAt: Date,
        dispatchedAt: Date? = nil,
        attempts: Int = 0,
        lastError: String? = nil
    ) {
        self.fingerprint = fingerprint
        self.url = url
        self.noteRelativePath = noteRelativePath
        self.status = status
        self.createdAt = createdAt
        self.dispatchedAt = dispatchedAt
        self.attempts = attempts
        self.lastError = lastError
    }

    enum CodingKeys: String, CodingKey {
        case fingerprint, url, noteRelativePath, status, createdAt, dispatchedAt, attempts, lastError
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fingerprint = try c.decode(String.self, forKey: .fingerprint)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        noteRelativePath = try c.decodeIfPresent(String.self, forKey: .noteRelativePath) ?? ""
        // Decoded via raw String so an unknown value (newer build's case, hand-edit,
        // corruption) degrades to .failed instead of throwing — a throw in one array
        // element would reset ALL of state.json via StateStore's nil fallback (the
        // TriageMode lesson in Settings).
        let statusRaw = try c.decodeIfPresent(String.self, forKey: .status)
        status = statusRaw.flatMap(Status.init(rawValue:)) ?? .failed
        // distantPast → immediately TTL-expired, so a dateless entry prunes itself.
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        dispatchedAt = try c.decodeIfPresent(Date.self, forKey: .dispatchedAt)
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
    }
}
