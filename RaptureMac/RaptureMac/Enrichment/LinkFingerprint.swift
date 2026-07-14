import Foundation

/// The content identity a link is enriched (and deduplicated) by — the user's
/// proven rulebook rules: YouTube = the video ID (query params vary, the ID
/// doesn't); articles = the normalized URL. Pure.
enum LinkFingerprint {
    /// Query parameters that are pure click-tracking noise and never change
    /// what page is served.
    nonisolated static let trackingParamPrefixes = ["utm_"]
    nonisolated static let trackingParamNames: Set<String> = ["fbclid", "gclid", "igshid"]

    /// `"yt:<videoID>"` for YouTube links, `"url:<normalized>"` for articles;
    /// nil = not enrichable (unparseable URL, non-http scheme, no video ID).
    nonisolated static func fingerprint(rawMedia: String, type: CaptureType) -> String? {
        guard let url = URL(string: rawMedia) else { return nil }
        switch type {
        case .youtubeLink:
            guard let id = TitleDeriver.youTubeVideoID(url) else { return nil }
            return "yt:\(id)"
        case .articleLink:
            guard let normalized = normalizedArticleURL(url) else { return nil }
            return "url:\(normalized)"
        case .voiceNote, .task, .idea, .journal:
            return nil
        }
    }

    /// Lowercased scheme+host, fragment dropped, tracking params dropped
    /// (remaining params kept in original order — conservative: reordering
    /// could merge genuinely different pages), one trailing slash stripped
    /// from a non-root path (root path ≡ empty). http(s) only.
    nonisolated static func normalizedArticleURL(_ url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty
        else { return nil }

        components.scheme = scheme
        components.host = host
        components.fragment = nil

        if let items = components.queryItems {
            let kept = items.filter { item in
                let name = item.name.lowercased()
                if trackingParamNames.contains(name) { return false }
                return !trackingParamPrefixes.contains(where: { name.hasPrefix($0) })
            }
            components.queryItems = kept.isEmpty ? nil : kept
        }

        var path = components.path
        if path == "/" {
            path = ""
        } else if path.hasSuffix("/") {
            path.removeLast()
        }
        components.path = path

        return components.string
    }
}
