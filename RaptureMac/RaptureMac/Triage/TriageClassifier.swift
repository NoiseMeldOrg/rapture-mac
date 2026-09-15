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
        let trimmed = stripLeadingHeading(text).trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Drops a leading Markdown H1 (`# <title>`) before the dominance count.
    /// The iPhone relay body opens with one — the page or note title the iOS
    /// app derived — and a title is the link's *name*, not commentary about
    /// it. Without this, every link share whose page title ran past six
    /// words counted as a voice note and AI triage filed it under Ideas or
    /// Tasks, where link enrichment and the transcript pipeline never look:
    /// 32 of them in the eight days after the share card began sending the
    /// real title (found 2026-09-15). Only the first line, only `# ` — a
    /// `#hashtag` or a `#` inside prose is left alone.
    nonisolated static func stripLeadingHeading(_ text: String) -> String {
        let leadingTrimmed = text.drop(while: { $0 == "\n" || $0 == "\r" || $0 == " " || $0 == "\t" })
        guard leadingTrimmed.hasPrefix("# ") else { return text }
        guard let newline = leadingTrimmed.firstIndex(where: { $0.isNewline }) else { return "" }
        return String(leadingTrimmed[newline...])
    }

    nonisolated static func isYouTubeHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "youtube.com"
            || host == "youtu.be"
            || host.hasSuffix(".youtube.com")
    }
}
