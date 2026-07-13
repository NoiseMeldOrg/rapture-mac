import Foundation

/// The capture contract: every triaged note is Markdown with YAML frontmatter
/// (`captured`, optional `source`, `type`, optional `raw_media`), the body, an
/// optional `## Raw` section (only when a formatter produced a body that differs
/// from the verbatim transcription — raw text is never discarded), and an optional
/// attachments footer of markdown links. Also home to the pure parsers the backlog
/// path needs: source-filename inference and the legacy `Attachments:` footer.
/// All pure, golden-tested.
enum CaptureContract {

    struct Note: Equatable, Sendable {
        var capturedAt: Date
        var source: CaptureSource?
        var type: CaptureType
        var rawMedia: String?
        var body: String
        /// Verbatim transcription when it differs from `body`; nil in M1 (nothing
        /// formats bodies yet — the invariant machinery ships ahead of M4).
        var rawBody: String?
    }

    struct FooterAttachment: Equatable, Sendable {
        let folder: String
        let filename: String
    }

    struct SourceFilenameInfo: Equatable, Sendable {
        let capturedAt: Date?
        let source: CaptureSource?
        let relayTitle: String?
    }

    struct ParsedFooter: Equatable, Sendable {
        let bodyWithoutFooter: String
        let attachments: [FooterAttachment]
    }

    // MARK: - Compose

    nonisolated static func compose(_ note: Note, attachments: [FooterAttachment] = []) -> String {
        var header = ["---", "captured: \(iso8601(note.capturedAt))"]
        if let source = note.source {
            header.append("source: \(source.rawValue)")
        }
        header.append("type: \(note.type.rawValue)")
        if let rawMedia = note.rawMedia {
            header.append("raw_media: \(rawMedia)")
        }
        header.append("---")

        var out = header.joined(separator: "\n") + "\n\n"
        var hasContent = false

        if !note.body.isEmpty {
            out += note.body + "\n"
            hasContent = true
        }

        if let rawBody = note.rawBody, rawBody != note.body {
            out += (hasContent ? "\n" : "") + "## Raw\n\n" + rawBody + "\n"
            hasContent = true
        }

        if !attachments.isEmpty {
            let lines = attachments.map { "- [\($0.filename)](<\($0.folder)/\($0.filename)>)" }
            out += (hasContent ? "\n" : "") + "Attachments:\n" + lines.joined(separator: "\n") + "\n"
        }

        return out
    }

    /// `YYYY-MM-DD <Title>` using the **local** calendar date of the capture (the
    /// human-facing filename matches the wall clock when it was dictated); the exact
    /// UTC instant lives in the `captured` frontmatter.
    nonisolated static func filenameBase(
        title: String,
        capturedAt: Date,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: capturedAt) + " " + title
    }

    // MARK: - Backlog filename parsing

    /// Infers capture time and origin from a pending file's name. Filename-shape
    /// source inference is a backlog-only heuristic (historically, only FileWriter
    /// produced pure-ISO names and only the iOS relay produced `<ISO> <title>`);
    /// live captures carry their source authoritatively via compose-direct, and
    /// anything non-contract-shaped stays `source`-less per the PRD.
    nonisolated static func parseSourceFilename(_ filename: String) -> SourceFilenameInfo {
        let base = (filename as NSString).deletingPathExtension
        guard let stamp = RelayWatcher.parseRelayTimestamp(base) else {
            return SourceFilenameInfo(capturedAt: nil, source: nil, relayTitle: nil)
        }
        let remainder = String(base.dropFirst(20))

        // Whitespace-only remainders count as pure timestamps: a stray trailing
        // space must not discard an already-parsed capture instant and source.
        if remainder.trimmingCharacters(in: .whitespaces).isEmpty || isCollisionSuffix(remainder) {
            return SourceFilenameInfo(capturedAt: stamp, source: .raptureMac, relayTitle: nil)
        }
        // One rule for "the title after a contract timestamp": TitleDeriver owns it.
        if let title = TitleDeriver.relayTitle(fromBaseName: base) {
            return SourceFilenameInfo(capturedAt: stamp, source: .raptureIOS, relayTitle: title)
        }
        return SourceFilenameInfo(capturedAt: nil, source: nil, relayTitle: nil)
    }

    // MARK: - Legacy footer parsing

    /// Structural parse of a trailing `Attachments:` block in a raw `.txt` body
    /// (the `FileWriter.composeBody` format). Returns nil unless every line under
    /// the marker is a well-formed `- folder/filename` entry — a lookalike block in
    /// prose is body text, not a footer. Whether the referenced folder actually
    /// exists is the caller's (I/O) concern.
    nonisolated static func parseFooter(_ text: String) -> ParsedFooter? {
        let marker = "Attachments:\n"
        let bodyPart: Substring
        let footerPart: Substring

        if text.hasPrefix(marker) {
            bodyPart = Substring("")
            footerPart = text.dropFirst(marker.count)
        } else if let range = text.range(of: "\n\n" + marker, options: .backwards) {
            bodyPart = text[..<range.lowerBound]
            footerPart = text[range.upperBound...]
        } else {
            return nil
        }

        var attachments: [FooterAttachment] = []
        for line in footerPart.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard trimmed.hasPrefix("- ") else { return nil }
            let path = String(trimmed.dropFirst(2))
            guard let slash = path.lastIndex(of: "/") else { return nil }
            let folder = String(path[..<slash])
            let filename = String(path[path.index(after: slash)...])
            guard !folder.isEmpty, !filename.isEmpty else { return nil }
            attachments.append(FooterAttachment(folder: folder, filename: filename))
        }
        guard !attachments.isEmpty else { return nil }
        return ParsedFooter(bodyWithoutFooter: String(bodyPart), attachments: attachments)
    }

    // MARK: - Helpers

    /// Destination-relative path (what `TriagedEntry.mdRelativePath` stores).
    /// Falls back to the last path component if `url` isn't under `folder`.
    nonisolated static func relativePath(of url: URL, in folder: URL) -> String {
        let folderPath = folder.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        guard filePath.hasPrefix(prefix) else { return url.lastPathComponent }
        return String(filePath.dropFirst(prefix.count))
    }

    nonisolated static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    nonisolated private static func isCollisionSuffix(_ s: String) -> Bool {
        guard s.hasPrefix("-") else { return false }
        let digits = s.dropFirst()
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }
}
