import Foundation

/// One settled root `.txt` ready to triage, as observed by `TriageWatcher`.
/// Deliberately carries only the filename: the processor re-derives the full path
/// from the *current* output folder inside the capture gate, so a candidate from a
/// pre-relocation snapshot can never be read from (or written back to) a stale root.
struct TriageCandidate: Equatable, Sendable {
    let filename: String
}

/// One watcher scan's worth of work. Fully re-derivable: anything the processor
/// defers simply reappears in the next scan.
struct TriageScanBatch: Equatable, Sendable {
    let candidates: [TriageCandidate]
}
