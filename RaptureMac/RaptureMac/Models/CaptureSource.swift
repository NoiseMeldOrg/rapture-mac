import Foundation

/// The capture contract's `source` frontmatter value: which app captured the note.
/// Omitted from the contract entirely when unknowable (e.g. a hand-dropped file).
enum CaptureSource: String, Codable, Sendable, Equatable {
    case raptureMac = "rapture-mac"
    case raptureIOS = "rapture-ios"
    case raptureAndroid = "rapture-android"
}
