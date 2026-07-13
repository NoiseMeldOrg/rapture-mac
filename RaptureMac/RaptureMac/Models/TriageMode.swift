import Foundation

/// How captures are filed into the destination. `.full` is the product default:
/// every capture becomes a Markdown note carrying the capture contract, classified
/// into subfolders (`Notes/`, `Links/`). `.raw` is the power-user escape hatch:
/// plain `.txt` at the destination root, exactly the pre-triage behavior.
enum TriageMode: String, Codable, CaseIterable, Sendable {
    case full
    case raw
}
