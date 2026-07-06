import Foundation

/// A relay `.txt` that is ready to file, paired with its `.m4a` when the audio is
/// fully downloaded at scan time. Produced by `RelayWatcher`, consumed by
/// `RelayProcessor`.
struct RelayCandidate: Sendable, Equatable {
    let txtURL: URL
    /// The paired audio file, only when it is visible (not a placeholder) at scan time.
    let audioURL: URL?
    /// The relay file's `lastPathComponent`; the dedup identity across restarts/re-syncs.
    let relayFilename: String
    /// The filename minus its `.txt` extension. Used verbatim as the output basename
    /// (the iPhone already writes names in the Rapture Notes convention).
    let baseName: String
}

/// One scan's worth of work. Each scan is a full snapshot of the relay folder, so a
/// batch is re-derivable: anything not processed re-appears in the next batch.
struct RelayScanBatch: Sendable, Equatable {
    var candidates: [RelayCandidate]
    /// `.m4a` files whose `.txt` never appeared (or was already filed and removed).
    var orphanAudio: [URL]
}
