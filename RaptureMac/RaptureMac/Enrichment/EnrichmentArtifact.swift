import Foundation

/// Pure compose/append helpers for enrichment artifacts. The artifact lives in
/// `Links/Media/`; the note it belongs to lives in `Links/` — so the artifact's
/// `capture:` pointer walks up one level and the note's appended link walks
/// down into `Media/`. Both are vault-agnostic relative paths.
enum EnrichmentArtifact {

    enum Kind: String, Sendable {
        case youtubeTranscript = "youtube-transcript"
        case articleExtract = "article-extract"
    }

    // MARK: - Artifact file

    /// Frontmatter mirrors the capture contract's informal YAML: source URL
    /// (verbatim as captured), fetch date, pointer to the capture note, kind.
    /// Body is the raw extract — no summarization.
    nonisolated static func compose(
        source: String,
        fetchedAt: Date,
        captureNoteFilename: String,
        kind: Kind,
        body: String
    ) -> String {
        let header = [
            "---",
            "source: \(source)",
            "fetched: \(CaptureContract.iso8601(fetchedAt))",
            "capture: ../\(captureNoteFilename)",
            "type: \(kind.rawValue)",
            "---"
        ]
        return header.joined(separator: "\n") + "\n\n" + body + "\n"
    }

    // MARK: - Note append

    nonisolated static let mediaMarker = "Media:\n"

    /// Returns the note markdown with a `Media:` block linking the artifact —
    /// inserted BEFORE a trailing `Attachments:` footer when one exists
    /// (`CaptureContract.rewriteFooterFolder` structurally parses everything
    /// after that marker; appending below it would break footer rewrites
    /// forever), else appended at the end. nil when an identical link is
    /// already present (idempotent — iCloud re-deliveries, crash replays).
    nonisolated static func appendingMediaLink(
        toMarkdown text: String,
        label: String,
        target: String
    ) -> String? {
        let line = "- [\(label)](<\(target)>)"
        guard !text.contains(line) else { return nil }
        let block = mediaMarker + line + "\n"

        if let footerRange = text.range(of: "\n" + "Attachments:\n", options: .backwards) {
            let head = text[..<footerRange.lowerBound]
            let tail = text[footerRange.lowerBound...]
            let separator = head.hasSuffix("\n") ? "\n" : "\n\n"
            return String(head) + separator + block + "\n" + String(tail.dropFirst())
        }

        let separator = text.hasSuffix("\n\n") ? "" : (text.hasSuffix("\n") ? "\n" : "\n\n")
        return text + separator + block
    }
}
