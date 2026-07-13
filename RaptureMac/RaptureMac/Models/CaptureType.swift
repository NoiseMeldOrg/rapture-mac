import Foundation

/// The capture contract's `type` frontmatter value. Deterministic triage produces
/// these three; the AI tier (M4) may refine to task/idea/journal/link later.
enum CaptureType: String, Codable, Sendable, Equatable {
    case voiceNote = "voice-note"
    case youtubeLink = "youtube-link"
    case articleLink = "article-link"

    /// Destination subfolder for this type.
    var subfolder: String {
        switch self {
        case .voiceNote: return "Notes"
        case .youtubeLink, .articleLink: return "Links"
        }
    }
}
