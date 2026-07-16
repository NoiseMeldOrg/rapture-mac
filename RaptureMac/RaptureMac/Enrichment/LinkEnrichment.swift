import Foundation

/// The enrichment seam between the four filing processors and the worker.
/// `noteFiled` is synchronous and non-blocking on the main actor — it never
/// touches disk or network — so processors already holding the capture gate
/// (TriageProcessor, DestinationMonitor) can call it safely.
@MainActor
protocol LinkEnriching: AnyObject {
    func noteFiled(noteURL: URL, in folder: URL, echo: LinkNoteEcho)
}

/// Echoed by the composers (via `WriteResult.link`) when a `.full`-mode capture
/// filed as a link note — everything enrichment needs, so the processor never
/// re-reads the capture text.
struct LinkNoteEcho: Sendable, Equatable {
    /// `.youtubeLink` or `.articleLink` only.
    var type: CaptureType
    /// The classifier's URL string, verbatim from the capture.
    var rawMedia: String
    var capturedAt: Date
}

/// What a successful fetch produced: the real title (for the rename; nil keeps
/// the deterministic name) and the artifact body (plain-paragraph transcript /
/// extracted article text).
struct FetchedLinkContent: Sendable, Equatable {
    var title: String?
    var bodyMarkdown: String
}

/// Typed fetch failures. The transport/content split drives the retry policy:
/// transport-class errors retry on the schedule, content-class errors
/// (`noCaptions`, `unusableContent`) give up immediately — a retry can't fix them.
enum LinkFetchError: Error, Equatable {
    case timeout
    case network(String)
    case http(Int)
    /// The video has no caption tracks (content-class; no retry).
    case noCaptions
    /// Extraction produced nothing usable (content-class; no retry).
    case unusableContent
    /// The URL is not safe to fetch — non-http(s) scheme or a loopback/private
    /// host literal (see `LinkFetchPolicy`). Content-class: give up quietly, the
    /// note stays as filed.
    case blockedURL
    /// Front-guard under XCTest; the test host must never fetch.
    case unavailable

    /// Transport-class failures consume the retry schedule; content-class do not.
    var isTransport: Bool {
        switch self {
        case .timeout, .network, .http: return true
        case .noCaptions, .unusableContent, .blockedURL, .unavailable: return false
        }
    }
}
