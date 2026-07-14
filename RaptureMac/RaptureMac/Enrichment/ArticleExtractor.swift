import Foundation

/// Hand-rolled readability-style text extraction — pure string processing, no
/// WebKit/DOM (both need the main thread; this runs off-actor on multi-MB
/// pages). Best-effort by design: JS-rendered and paywalled pages simply come
/// back thin and the caller gives up quietly.
enum ArticleExtractor {
    /// Extraction residue shorter than this is judged unusable (nav crumbs,
    /// cookie banners, "enable JavaScript" shells).
    nonisolated static let minimumUsableChars = 200

    // MARK: - Title

    /// og:title wins over `<title>` (the latter usually carries " — Site Name" noise).
    nonisolated static func title(fromHTML html: String) -> String? {
        if let og = metaContent(property: "og:title", in: html), !og.isEmpty {
            return decodeEntities(og)
        }
        if let range = firstTagBody(named: "title", in: html) {
            let title = decodeEntities(String(html[range])).trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : title
        }
        return nil
    }

    // MARK: - Readable text

    /// Strip chrome elements, prefer `<article>`/`<main>`/`<body>`, favor
    /// `<p>`-tagged text, block tags → paragraphs, entities decoded. nil when
    /// the residue is too thin to be an article.
    nonisolated static func readableText(fromHTML html: String) -> String? {
        var working = removing(["<!--(?s).*?-->"], from: html)
        working = removing(strippedElements.map { "(?is)<\($0)\\b[^>]*>.*?</\($0)>" }, from: working)

        // Narrow to the most article-shaped container available.
        for container in ["article", "main", "body"] {
            if let range = firstTagBody(named: container, in: working) {
                working = String(working[range])
                break
            }
        }

        // Articles carry their prose in <p> tags; prefer exactly that text and
        // fall back to a whole-container strip only when it comes back thin.
        let fromParagraphs = paragraphText(in: working)
        let text: String
        if let fromParagraphs, fromParagraphs.count >= minimumUsableChars {
            text = fromParagraphs
        } else {
            text = plainText(strippingTagsFrom: working)
        }

        return text.count >= minimumUsableChars ? text : nil
    }

    // MARK: - Internals

    /// Elements removed with their entire contents before extraction.
    nonisolated static let strippedElements = [
        "script", "style", "noscript", "svg", "head", "nav",
        "header", "footer", "aside", "form", "iframe", "template", "button", "select"
    ]

    private nonisolated static func removing(_ patterns: [String], from text: String) -> String {
        var result = text
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return result
    }

    /// The body of the first `<name …>…</name>` pair, or nil.
    private nonisolated static func firstTagBody(named name: String, in html: String) -> Range<String.Index>? {
        guard let openMatch = html.range(of: "(?i)<\(name)(\\s[^>]*)?>", options: .regularExpression),
              let closeMatch = html.range(of: "(?i)</\(name)>", options: .regularExpression, range: openMatch.upperBound..<html.endIndex)
        else { return nil }
        return openMatch.upperBound..<closeMatch.lowerBound
    }

    /// Joined text of every `<p>` (and heading/list-item) element, one
    /// paragraph each; list items keep their dash.
    private nonisolated static func paragraphText(in html: String) -> String? {
        var paragraphs: [String] = []
        let pattern = "(?is)<(p|h[1-6]|li)\\b[^>]*>(.*?)</\\1>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = html as NSString
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range(at: 1)).lowercased()
            let body = ns.substring(with: match.range(at: 2))
            let text = plainText(strippingTagsFrom: body)
            if !text.isEmpty { paragraphs.append(tag == "li" ? "- " + text : text) }
        }
        guard !paragraphs.isEmpty else { return nil }
        return paragraphs.joined(separator: "\n\n")
    }

    /// Block-tag closes become paragraph breaks, list items become dashes, all
    /// remaining tags drop, entities decode, whitespace collapses.
    private nonisolated static func plainText(strippingTagsFrom html: String) -> String {
        var text = html
        text = text.replacingOccurrences(
            of: "(?i)</(p|div|h[1-6]|li|blockquote|tr|section|article)>", with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<li\\b[^>]*>", with: "- ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = decodeEntities(text)

        let lines = text
            .components(separatedBy: "\n")
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }
        var collapsed: [String] = []
        var blankRun = 0
        for line in lines {
            if line.isEmpty {
                blankRun += 1
                if blankRun == 1, !collapsed.isEmpty { collapsed.append("") }
            } else {
                blankRun = 0
                collapsed.append(line)
            }
        }
        while collapsed.last?.isEmpty == true { collapsed.removeLast() }
        return collapsed.joined(separator: "\n").replacingOccurrences(of: "\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func metaContent(property: String, in html: String) -> String? {
        // Attribute order varies: property before content and vice versa.
        let patterns = [
            "(?is)<meta\\b[^>]*(?:property|name)\\s*=\\s*[\"']\(property)[\"'][^>]*content\\s*=\\s*[\"']([^\"']*)[\"']",
            "(?is)<meta\\b[^>]*content\\s*=\\s*[\"']([^\"']*)[\"'][^>]*(?:property|name)\\s*=\\s*[\"']\(property)[\"']"
        ]
        let ns = html as NSString
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
               match.numberOfRanges > 1 {
                let content = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty { return content }
            }
        }
        return nil
    }

    /// Named + numeric HTML entity decoding (the common set; exotic named
    /// entities pass through untouched — honest raw extract).
    nonisolated static func decodeEntities(_ text: String) -> String {
        var result = text
        let named: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
            "&nbsp;": "\u{00A0}", "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}",
            "&rdquo;": "\u{201D}", "&ldquo;": "\u{201C}", "&mdash;": "\u{2014}",
            "&ndash;": "\u{2013}", "&hellip;": "\u{2026}", "&copy;": "\u{00A9}"
        ]
        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        // Numeric: &#8217; and &#x2019;
        for (pattern, radix) in [("&#([0-9]{1,7});", 10), ("&#[xX]([0-9a-fA-F]{1,6});", 16)] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            while true {
                let ns = result as NSString
                guard let match = regex.firstMatch(in: result, range: NSRange(location: 0, length: ns.length)),
                      match.numberOfRanges > 1,
                      let code = UInt32(ns.substring(with: match.range(at: 1)), radix: radix),
                      let scalar = Unicode.Scalar(code)
                else { break }
                result = ns.replacingCharacters(in: match.range, with: String(Character(scalar)))
            }
        }
        return result
    }
}
