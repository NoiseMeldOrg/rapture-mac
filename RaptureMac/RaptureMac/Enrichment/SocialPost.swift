import Foundation

/// Pure parsing for public Facebook, Instagram, Threads and X posts. No
/// networking and no state: every function takes its input as an argument, so
/// it is unit-tested with inline fixtures and runs off the main actor on
/// multi-hundred-KB pages. The fetching lives in `URLSessionLinkFetcher`, the
/// only enrichment file allowed to touch `URLSession`.
///
/// Why this exists: Facebook, Instagram and Threads send a logged-out browser
/// an empty page, so `ArticleExtractor` gets nothing. They send the full page
/// (with `og:` tags) to Meta's own link-preview crawler, so the fetcher asks
/// the way that crawler does and this file reads the tags. X serves the post
/// text from its public embed feed, with oEmbed as the fallback. Best-effort:
/// a private, removed or logged-out post comes back as `nil` here and the
/// service gives up quietly, content-class, with no retry.
///
/// Ported from the tested Python reference in the `extract-social-post` skill
/// (`social_extract.py`).
nonisolated enum SocialPost {

    nonisolated enum Platform: String, Sendable, Equatable {
        case facebook
        case instagram
        case threads
        case x

        /// Only Facebook and X videos can be transcribed: the pipeline reads
        /// those with no browser login. Instagram and Threads videos need one,
        /// so a dispatch would waste a session.
        var canTranscribeVideo: Bool {
            self == .facebook || self == .x
        }
    }

    // MARK: - Platform and URL helpers

    /// The platform a host belongs to. The host must equal a known domain or be
    /// a dot-suffix of it, so `notfacebook.com` and `facebook.com.evil.example`
    /// never match.
    static func platform(forHost host: String) -> Platform? {
        let host = host.lowercased()
        func on(_ domains: String...) -> Bool {
            domains.contains { host == $0 || host.hasSuffix("." + $0) }
        }
        if on("facebook.com", "fb.watch") { return .facebook }
        if on("instagram.com", "instagr.am") { return .instagram }
        if on("threads.net", "threads.com") { return .threads }
        if on("x.com", "twitter.com") { return .x }
        return nil
    }

    static func platform(for url: URL) -> Platform? {
        guard let host = url.host else { return nil }
        return platform(forHost: host)
    }

    /// Path markers that mean "this Meta link is a video". Also `fb.watch`.
    static let videoPathMarkers = ["/share/v/", "/share/r/", "/reel/", "/reels/", "/videos/", "/watch"]

    static func looksLikeVideoURL(_ url: URL) -> Bool {
        if url.host?.lowercased() == "fb.watch" { return true }
        let path = url.path.lowercased()
        return videoPathMarkers.contains { path.contains($0) }
    }

    /// The post number in an X link: `/status/<id>` or `/statuses/<id>`.
    static func tweetID(from url: URL) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "/status(?:es)?/([0-9]+)") else { return nil }
        let path = url.path
        let ns = path as NSString
        guard let match = regex.firstMatch(in: path, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    // MARK: - Request shapes (the fetcher owns the transport)

    /// Meta's own link-preview crawler. Facebook, Instagram and Threads answer
    /// a normal browser with a stub and this user agent with the full page.
    static let crawlerUserAgent = "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)"

    /// The public embed feed that powers embedded posts. No login needed.
    static func syndicationURL(tweetID: String) -> URL? {
        guard !tweetID.isEmpty, tweetID.allSatisfy(\.isASCII), tweetID.allSatisfy(\.isNumber) else { return nil }
        return URL(string: "https://cdn.syndication.twimg.com/tweet-result?id=\(tweetID)&lang=en&token=a")
    }

    static func oEmbedURL(forPostURL postURL: URL) -> URL? {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        guard let encoded = postURL.absoluteString.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: "https://publish.twitter.com/oembed?omit_script=1&url=\(encoded)")
    }

    // MARK: - Meta pages: tags

    /// The `<meta property|name=... content=...>` pairs of a page. Attributes
    /// may come in any order, with single, double or no quotes; the first tag
    /// of each name wins; values are entity-decoded. A scanner rather than a
    /// regex so a `>` inside a quoted value does not end the tag early, and so
    /// `<meta` inside a script, a style or a comment is never read as a tag.
    static func parseMeta(_ html: String) -> [String: String] {
        let bytes = Array(html.utf8)
        let count = bytes.count
        var meta: [String: String] = [:]
        var i = 0

        while i < count {
            guard bytes[i] == ascii("<") else { i += 1; continue }

            if startsWith(bytes, at: i, "<!--") {
                i = index(of: "-->", in: bytes, from: i + 4).map { $0 + 3 } ?? count
                continue
            }
            if let name = rawTextElement(at: i, in: bytes) {
                // Script and style bodies are text, not markup: skip to the close.
                i = index(ofCaseInsensitive: "</" + name, in: bytes, from: i + 1 + name.utf8.count) ?? count
                if i < count { i += 2 + name.utf8.count }
                continue
            }
            if startsWith(bytes, at: i, "<meta", caseInsensitive: true), tagNameEnds(at: i + 5, in: bytes) {
                let (attributes, end) = parseAttributes(in: bytes, from: i + 5)
                i = end
                let key = (attributes["property"].flatMap { $0.isEmpty ? nil : $0 } ?? attributes["name"] ?? "").lowercased()
                if !key.isEmpty, let content = attributes["content"], meta[key] == nil {
                    meta[key] = decodeEntities(content)
                }
                continue
            }
            i += 1
        }
        return meta
    }

    private static func ascii(_ s: Unicode.Scalar) -> UInt8 { UInt8(ascii: s) }

    private static func lower(_ byte: UInt8) -> UInt8 {
        (byte >= 65 && byte <= 90) ? byte + 32 : byte
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 12
    }

    private static func startsWith(_ bytes: [UInt8], at start: Int, _ needle: String, caseInsensitive: Bool = false) -> Bool {
        matches(bytes, at: start, Array(needle.utf8), caseInsensitive: caseInsensitive)
    }

    private static func matches(_ bytes: [UInt8], at start: Int, _ needle: [UInt8], caseInsensitive: Bool) -> Bool {
        guard start >= 0, start + needle.count <= bytes.count else { return false }
        for k in 0..<needle.count {
            let a = caseInsensitive ? lower(bytes[start + k]) : bytes[start + k]
            let b = caseInsensitive ? lower(needle[k]) : needle[k]
            if a != b { return false }
        }
        return true
    }

    private static func index(of needle: String, in bytes: [UInt8], from start: Int) -> Int? {
        index(of: needle, in: bytes, from: start, caseInsensitive: false)
    }

    private static func index(ofCaseInsensitive needle: String, in bytes: [UInt8], from start: Int) -> Int? {
        index(of: needle, in: bytes, from: start, caseInsensitive: true)
    }

    /// Forward search for `needle`; the needle is turned into bytes once, not at every position.
    private static func index(of needle: String, in bytes: [UInt8], from start: Int, caseInsensitive: Bool) -> Int? {
        let target = Array(needle.utf8)
        guard !target.isEmpty, start >= 0, bytes.count >= target.count else { return nil }
        var i = start
        let last = bytes.count - target.count
        while i <= last {
            if matches(bytes, at: i, target, caseInsensitive: caseInsensitive) { return i }
            i += 1
        }
        return nil
    }

    /// True when the tag name that began just before `position` ends there
    /// (whitespace, `/` or `>`), so `<metadata>` is not a `<meta>` tag.
    private static func tagNameEnds(at position: Int, in bytes: [UInt8]) -> Bool {
        guard position < bytes.count else { return true }
        let b = bytes[position]
        return isSpace(b) || b == ascii("/") || b == ascii(">")
    }

    /// "script" or "style" when a raw-text element opens at `position`.
    private static func rawTextElement(at position: Int, in bytes: [UInt8]) -> String? {
        for name in ["script", "style"] {
            if startsWith(bytes, at: position, "<" + name, caseInsensitive: true),
               tagNameEnds(at: position + 1 + name.utf8.count, in: bytes) {
                return name
            }
        }
        return nil
    }

    /// Reads attributes from `start` up to the closing `>` (outside quotes).
    /// Returns them (lowercased names, first wins) and the index after the tag.
    private static func parseAttributes(in bytes: [UInt8], from start: Int) -> ([String: String], Int) {
        var attributes: [String: String] = [:]
        let count = bytes.count
        var i = start
        let quoteDouble = ascii("\""), quoteSingle = ascii("'")

        while i < count {
            while i < count, isSpace(bytes[i]) || bytes[i] == ascii("/") { i += 1 }
            guard i < count else { break }
            if bytes[i] == ascii(">") { return (attributes, i + 1) }

            let nameStart = i
            while i < count, !isSpace(bytes[i]), bytes[i] != ascii("="), bytes[i] != ascii(">"), bytes[i] != ascii("/") { i += 1 }
            let name = String(decoding: bytes[nameStart..<i], as: UTF8.self).lowercased()
            if i == nameStart { i += 1; continue }   // stray byte; never loop in place

            while i < count, isSpace(bytes[i]) { i += 1 }
            var value = ""
            if i < count, bytes[i] == ascii("=") {
                i += 1
                while i < count, isSpace(bytes[i]) { i += 1 }
                if i < count, bytes[i] == quoteDouble || bytes[i] == quoteSingle {
                    let quote = bytes[i]
                    i += 1
                    let valueStart = i
                    while i < count, bytes[i] != quote { i += 1 }
                    value = String(decoding: bytes[valueStart..<i], as: UTF8.self)
                    if i < count { i += 1 }
                } else {
                    let valueStart = i
                    while i < count, !isSpace(bytes[i]), bytes[i] != ascii(">") { i += 1 }
                    value = String(decoding: bytes[valueStart..<i], as: UTF8.self)
                }
            }
            if attributes[name] == nil { attributes[name] = value }
        }
        return (attributes, count)
    }

    // MARK: - Meta pages: text

    /// Strips the engagement counts Facebook puts in front of the post text:
    /// `36 reactions · 3 comments | `, `1.2K views · 45 reactions | `,
    /// `No reactions | `, `1 comment | `. Only a leading run is removed, so text
    /// that merely contains "5 reactions" later on stays as written.
    static func stripEngagementPrefix(_ title: String) -> String {
        let pattern = "^\\s*(?:(?:\\d[\\d.,]*\\s?[KMBkmb]?|No)\\s+(?:views?|reactions?|likes?|comments?|shares?|plays?)\\s*[·|]\\s*)+"
        var result = title
        if let range = result.range(of: pattern, options: .regularExpression) {
            result.removeSubrange(range)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What each site shows instead of a post when it wants a login (private,
    /// removed or logged out). Matched on the whole text, or on its start for
    /// the long sentences.
    private static let loginWallExact: Set<String> = [
        "facebook", "instagram", "threads", "login \u{2022} instagram",
        "facebook - log in or sign up", "facebook \u{2013} log in or sign up"
    ]
    private static let loginWallPrefixes = [
        "log in or sign up to view",
        "log in to facebook",
        "log into facebook",
        "see posts, photos and more on facebook",
        "create an account or log in to instagram",
        "sign up for instagram",
        "join threads"
    ]

    /// True when `text` is empty or login-wall boilerplate: nothing usable.
    static func isLoginWall(_ text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.isEmpty || loginWallExact.contains(lowered) { return true }
        return loginWallPrefixes.contains { lowered.hasPrefix($0) }
    }

    /// `og:title` holds the whole post (after the engagement counts);
    /// `og:description` is cut to 200 characters. A login-wall title means the
    /// whole page is the wall, so the description is boilerplate too.
    static func facebookText(meta: [String: String]) -> String {
        let title = stripEngagementPrefix(decodeEntities(meta["og:title"] ?? ""))
        let description = decodeEntities(meta["og:description"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if isLoginWall(title) { return "" }
        let text = title.count >= description.count ? title : description
        if isLoginWall(text) { return "" }
        return text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The caption: after `on Instagram: "` in `og:title`, or quoted at the end
    /// of `og:description`.
    static func instagramText(meta: [String: String]) -> String {
        let title = decodeEntities(meta["og:title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let description = decodeEntities(meta["og:description"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let caption = firstCapture(#"(?s)on Instagram:\s*["“](.*)["”]\s*$"#, in: title)
            ?? firstCapture(#"(?s):\s*["“](.*)["”]\.?\s*$"#, in: description)
            ?? ""
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        return isLoginWall(trimmed) ? "" : trimmed
    }

    /// The post text is `og:description`.
    static func threadsText(meta: [String: String]) -> String {
        let description = decodeEntities(meta["og:description"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return isLoginWall(description) ? "" : description
    }

    static func text(for platform: Platform, meta: [String: String]) -> String {
        switch platform {
        case .facebook: return facebookText(meta: meta)
        case .instagram: return instagramText(meta: meta)
        case .threads: return threadsText(meta: meta)
        case .x: return ""
        }
    }

    /// A Meta page is a video when `og:type` starts with `video`, an
    /// `og:video` tag exists, or any of the given URLs (as captured, after
    /// redirects, canonical) looks like a video link.
    static func isVideoPage(meta: [String: String], urls: [URL]) -> Bool {
        if (meta["og:type"] ?? "").lowercased().hasPrefix("video") { return true }
        // `og:video` itself, or its `og:video:url` / `og:video:secure_url` family.
        if meta.keys.contains(where: { $0 == "og:video" || $0.hasPrefix("og:video:") }) { return true }
        return urls.contains(where: looksLikeVideoURL)
    }

    /// The whole Meta-page result: post text as the artifact body, its first
    /// line as the title, and the video flag. nil when the page is a login
    /// wall or carries no text.
    static func post(fromMetaHTML html: String, platform: Platform, requestURL: URL, finalURL: URL?) -> FetchedLinkContent? {
        let meta = parseMeta(html)
        let text = text(for: platform, meta: meta)
        guard !text.isEmpty else { return nil }
        let canonical = meta["og:url"].flatMap { URL(string: $0) }
        let urls = [requestURL, finalURL, canonical].compactMap { $0 }
        return FetchedLinkContent(
            title: firstLineTitle(text),
            bodyMarkdown: text,
            isVideo: isVideoPage(meta: meta, urls: urls)
        )
    }

    // MARK: - X

    /// The post text from the embed feed's JSON: sliced to `display_text_range`
    /// (the range indexes Unicode scalars and drops trailing media links),
    /// short links expanded, remaining media links removed, entities decoded,
    /// and a quoted post appended. nil when the JSON is unreadable or has no
    /// `text` key at all.
    static func xText(fromSyndicationJSON data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var text = object["text"] as? String else { return nil }

        if let span = object["display_text_range"] as? [Any], span.count == 2,
           let start = (span[0] as? NSNumber)?.intValue, let end = (span[1] as? NSNumber)?.intValue {
            let scalars = Array(text.unicodeScalars)
            let low = max(0, min(start, scalars.count))
            let high = max(low, min(end, scalars.count))
            var sliced = String.UnicodeScalarView()
            sliced.append(contentsOf: scalars[low..<high])
            text = String(sliced)
        }

        let entities = object["entities"] as? [String: Any]
        for entry in (entities?["urls"] as? [[String: Any]]) ?? [] {
            guard let short = entry["url"] as? String, !short.isEmpty else { continue }
            let expanded = (entry["expanded_url"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? short
            text = text.replacingOccurrences(of: short, with: expanded)
        }
        for media in (object["mediaDetails"] as? [[String: Any]]) ?? [] {
            if let link = media["url"] as? String, !link.isEmpty {
                text = text.replacingOccurrences(of: link, with: "")
            }
        }
        text = decodeEntities(text).trimmingCharacters(in: .whitespacesAndNewlines)

        if let quoted = object["quoted_tweet"] as? [String: Any],
           let quotedText = quoted["text"] as? String, !quotedText.isEmpty {
            let screenName = ((quoted["user"] as? [String: Any])?["screen_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "someone"
            text += "\n\nQuoted post by @\(screenName): " + decodeEntities(quotedText).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A video shows up as a `video` object or a `mediaDetails` entry of type
    /// `video` or `animated_gif`.
    static func xIsVideo(fromSyndicationJSON data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let video = object["video"] as? [String: Any], !video.isEmpty { return true }
        return ((object["mediaDetails"] as? [[String: Any]]) ?? []).contains {
            let type = $0["type"] as? String
            return type == "video" || type == "animated_gif"
        }
    }

    /// The embed-feed result. nil when there is no usable text (the caller
    /// then asks oEmbed).
    static func post(fromSyndicationJSON data: Data) -> FetchedLinkContent? {
        guard let text = xText(fromSyndicationJSON: data), !text.isEmpty else { return nil }
        return FetchedLinkContent(title: firstLineTitle(text), bodyMarkdown: text, isVideo: xIsVideo(fromSyndicationJSON: data))
    }

    /// The fallback: the post text from oEmbed's `html` (`<blockquote><p>TEXT</p>`),
    /// `<br>` as a line break, tags dropped, entities decoded. Empty when absent.
    static func xText(fromOEmbedJSON data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let block = object["html"] as? String,
              let inner = firstCapture(#"(?s)<p[^>]*>(.*?)</p>"#, in: block) else { return "" }
        var text = inner.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return decodeEntities(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The oEmbed result. oEmbed does not say whether the post has a video.
    static func post(fromOEmbedJSON data: Data) -> FetchedLinkContent? {
        let text = xText(fromOEmbedJSON: data)
        guard !text.isEmpty else { return nil }
        return FetchedLinkContent(title: firstLineTitle(text), bodyMarkdown: text, isVideo: false)
    }

    // MARK: - Titles

    /// The first non-empty line of the post, at most `limit` characters; a
    /// longer line is cut to `limit - 1` characters plus an ellipsis. nil when
    /// the text has no non-blank line.
    static func firstLineTitle(_ text: String, limit: Int = 100) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) else { return nil }
        guard line.count > limit else { return line }
        let cut = String(line.prefix(max(limit - 1, 0))).trimmingCharacters(in: .whitespacesAndNewlines)
        return cut + "\u{2026}"
    }

    // MARK: - Shared text helpers

    /// First capture group of the first match, or nil.
    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}", "middot": "\u{00B7}",
        "bull": "\u{2022}", "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}"
    ]

    /// Named and numeric HTML entities, decoded in one left-to-right pass (so
    /// `&amp;lt;` becomes `&lt;`, never `<`). Unknown entities stay as written.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "&",
               let semicolon = text[index...].prefix(12).firstIndex(of: ";"),
               let decoded = decodeEntity(text[text.index(after: index)..<semicolon]) {
                result += decoded
                index = text.index(after: semicolon)
                continue
            }
            result.append(character)
            index = text.index(after: index)
        }
        return result
    }

    private static func decodeEntity(_ name: Substring) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let code: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                code = UInt32(digits.dropFirst(), radix: 16)
            } else {
                code = UInt32(digits, radix: 10)
            }
            guard let code, code != 0, let scalar = Unicode.Scalar(code) else { return nil }
            return String(Character(scalar))
        }
        return namedEntities[String(name)]
    }
}
