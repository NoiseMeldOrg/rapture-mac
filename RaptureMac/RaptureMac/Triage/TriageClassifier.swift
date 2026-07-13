import Foundation

/// Deterministic, zero-AI capture classification. A capture is a link when the
/// dictated text is URL-dominant: at least one *explicitly typed* URL (scheme or
/// `www.` present in the text — `NSDataDetector` also matches bare domains like
/// "apple.com" with an inferred scheme, and those must stay voice notes because
/// Siri produces them from ordinary speech) and at most a few words of commentary.
/// Pure; all rules unit-tested by table.
enum TriageClassifier {
    struct Classification: Equatable, Sendable {
        let type: CaptureType
        /// Absolute URL string for link types; nil for voice notes.
        let rawMedia: String?
    }

    /// Maximum words of non-URL commentary for a capture to remain link-typed.
    nonisolated static let maxCommentaryWords = 7

    nonisolated static func classify(_ text: String) -> Classification {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return Classification(type: .voiceNote, rawMedia: nil)
        }

        let ns = trimmed as NSString
        let matches = detector.matches(in: trimmed, range: NSRange(location: 0, length: ns.length))

        var qualifying: [(url: URL, range: NSRange)] = []
        for match in matches {
            guard let url = match.url else { continue }
            let sourceText = ns.substring(with: match.range).lowercased()
            if sourceText.hasPrefix("http://") || sourceText.hasPrefix("https://") || sourceText.hasPrefix("www.") {
                qualifying.append((url, match.range))
            }
        }
        guard let first = qualifying.first else {
            return Classification(type: .voiceNote, rawMedia: nil)
        }

        // URL-dominance: blank out every qualifying URL, count what's left.
        let mutable = NSMutableString(string: trimmed)
        for item in qualifying.sorted(by: { $0.range.location > $1.range.location }) {
            mutable.replaceCharacters(in: item.range, with: " ")
        }
        let commentaryWords = (mutable as String)
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .count
        guard commentaryWords <= maxCommentaryWords else {
            return Classification(type: .voiceNote, rawMedia: nil)
        }

        let type: CaptureType = isYouTubeHost(first.url) ? .youtubeLink : .articleLink
        return Classification(type: type, rawMedia: first.url.absoluteString)
    }

    nonisolated static func isYouTubeHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "youtube.com"
            || host == "youtu.be"
            || host.hasSuffix(".youtube.com")
    }
}
