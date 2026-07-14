import Foundation

/// Deterministic note titles: first words of the dictation for voice notes,
/// host/video-id for links, and the iOS-derived title part of relay basenames.
/// Smart imperative titles (filler stripping, rephrasing) are the AI tier's job
/// (M4); this tier is mechanical and pure.
enum TitleDeriver {
    nonisolated static let maxWords = 8
    nonisolated static let maxChars = 60
    nonisolated static let fallback = "Note"

    // MARK: - Voice notes

    nonisolated static func voiceNoteTitle(from text: String) -> String {
        let words = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .prefix(maxWords)
        var title = words.joined(separator: " ")

        // Filesystem-hostile characters become spaces; collapse the damage.
        title = title
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: ":", with: " ")
        title = title
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        while title.hasPrefix(".") {
            title.removeFirst()
        }
        title = title.trimmingCharacters(in: .whitespaces)

        if title.count > maxChars {
            title = truncateAtWordBoundary(title, limit: maxChars)
        }

        guard !title.isEmpty else { return fallback }
        return title.prefix(1).uppercased() + title.dropFirst()
    }

    // MARK: - Links

    nonisolated static func linkTitle(for urlString: String, type: CaptureType) -> String {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else {
            return type == .youtubeLink ? "YouTube" : "Link"
        }
        switch type {
        case .youtubeLink:
            if let id = youTubeVideoID(url) {
                return "YouTube \(id)"
            }
            return "YouTube"
        case .articleLink, .voiceNote, .task, .idea, .journal:
            // Only link types reach here in practice; the AI classes fall
            // through to the host-name fallback for exhaustiveness.
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            return bare.isEmpty ? "Link" : bare
        }
    }

    /// The slug after `v=` / `youtu.be/` / `shorts/` / `live/` / `embed/` — the same
    /// identity rule the user's routing rulebook deduplicates by.
    nonisolated static func youTubeVideoID(_ url: URL) -> String? {
        if let host = url.host?.lowercased(), host == "youtu.be" {
            let slug = url.pathComponents.dropFirst().first ?? ""
            return slug.isEmpty ? nil : slug
        }
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let v = items.first(where: { $0.name == "v" })?.value, !v.isEmpty {
            return v
        }
        let path = url.pathComponents.dropFirst()
        if let markerIndex = path.firstIndex(where: { ["shorts", "live", "embed"].contains($0.lowercased()) }),
           path.index(after: markerIndex) < path.endIndex {
            let slug = path[path.index(after: markerIndex)]
            return slug.isEmpty ? nil : slug
        }
        return nil
    }

    /// A fetched video/page title sanitized for use as a filename base (M5
    /// enrichment rename). Same filesystem-hostile-character rules as
    /// `voiceNoteTitle`, but the real title's own casing is kept and there is
    /// no word cap — only the 60-char boundary. nil = nothing usable; the
    /// caller keeps the deterministic name.
    nonisolated static func enrichedLinkTitle(from fetchedTitle: String) -> String? {
        var title = fetchedTitle
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: ":", with: " ")
        title = title
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        while title.hasPrefix(".") {
            title.removeFirst()
        }
        title = title.trimmingCharacters(in: .whitespaces)
        if title.count > maxChars {
            title = truncateAtWordBoundary(title, limit: maxChars)
        }
        return title.isEmpty ? nil : title
    }

    // MARK: - Relay basenames

    /// The title part of a contract-shaped relay basename (`<ISO-stamp> <title>`),
    /// or nil when the basename is a pure timestamp (with optional collision suffix)
    /// or not contract-shaped at all.
    nonisolated static func relayTitle(fromBaseName baseName: String) -> String? {
        guard RelayWatcher.parseRelayTimestamp(baseName) != nil else { return nil }
        let remainder = String(baseName.dropFirst(20))
        guard remainder.hasPrefix(" ") else { return nil }
        let title = remainder.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    // MARK: - Helpers

    /// Internal (not private): `HandoffDetector` reuses the same cap rule.
    nonisolated static func truncateAtWordBoundary(_ text: String, limit: Int) -> String {
        let hardCut = String(text.prefix(limit))
        if let lastSpace = hardCut.lastIndex(of: " ") {
            return String(hardCut[..<lastSpace]).trimmingCharacters(in: .whitespaces)
        }
        return hardCut.trimmingCharacters(in: .whitespaces)
    }
}
