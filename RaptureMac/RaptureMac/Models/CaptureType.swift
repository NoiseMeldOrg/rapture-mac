import Foundation

/// The capture contract's `type` frontmatter value. Deterministic triage produces
/// the first three; the AI tier (M4) may refine a voice note to task/idea/journal.
/// Link captures keep their deterministic youtube-link/article-link typing — M5's
/// enrichment dedups and renames by those, so AI never rewrites them.
enum CaptureType: String, Codable, Sendable, Equatable {
    case voiceNote = "voice-note"
    case youtubeLink = "youtube-link"
    case articleLink = "article-link"
    case task
    case idea
    case journal

    /// Destination subfolder for this type.
    var subfolder: String {
        switch self {
        case .voiceNote: return "Notes"
        case .youtubeLink, .articleLink: return "Links"
        case .task: return "Tasks"
        case .idea: return "Ideas"
        case .journal: return "Journal"
        }
    }
}
