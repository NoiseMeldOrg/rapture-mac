import Foundation

/// The one-line marker the Rapture iOS app puts at the top of a meeting relay
/// file (rapture-ios roadmap #75, milestone 4):
///
///     <!-- rapture-meeting id=<recording UUID> part=transcript|summary -->
///
/// A meeting reaches the relay twice: the transcript when it is ready, then a
/// summary (overview, decisions, to-dos, plus the full transcript) whenever the
/// user makes one, possibly more than once. Both parts carry the same `id`; the
/// Mac files them into ONE note keyed by that id (see `MeetingFiler`,
/// `MeetingLedger`). A relay file without the marker is an ordinary capture.
/// Pure, table-tested.
enum MeetingMarker {

    struct Header: Equatable, Sendable {
        let meetingId: String
        let part: MeetingPart
    }

    struct Parsed: Equatable, Sendable {
        let header: Header
        /// Everything after the marker line, leading blank lines dropped. This is
        /// the verbatim meeting body (it opens with the iOS `# <title>` line).
        let body: String
    }

    /// Longest id accepted. A UUID is 36; the cap only bounds hostile input.
    nonisolated static let maxIdLength = 64

    /// How much of a file `peek` reads. The marker is short; a first line
    /// longer than this is not a marker.
    nonisolated static let peekBytes = 1024

    /// Parses the marker from the first line of `text` and returns it with the
    /// body that follows. nil when the first line is not a well-formed marker —
    /// the caller then files the text exactly as before meetings existed.
    nonisolated static func parse(_ text: String) -> Parsed? {
        var rest = Substring(text)
        if rest.hasPrefix("\u{FEFF}") { rest = rest.dropFirst() }
        let firstLine: Substring
        let remainder: Substring
        if let newline = rest.firstIndex(where: \.isNewline) {
            firstLine = rest[..<newline]
            remainder = rest[rest.index(after: newline)...]
        } else {
            firstLine = rest
            remainder = ""
        }
        guard let header = parseHeader(firstLine) else { return nil }
        let body = remainder.drop(while: \.isNewline)
        return Parsed(header: header, body: String(body))
    }

    /// Parses one marker line. Keys may come in any order; unknown keys are
    /// ignored so iOS can add fields later without breaking older Macs.
    nonisolated static func parseHeader<S: StringProtocol>(_ line: S) -> Header? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<!--"), trimmed.hasSuffix("-->"), trimmed.count >= 7 else { return nil }
        let inner = trimmed.dropFirst(4).dropLast(3)
        let tokens = inner.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard tokens.first == "rapture-meeting" else { return nil }

        var id: String?
        var part: MeetingPart?
        for token in tokens.dropFirst() {
            guard let eq = token.firstIndex(of: "=") else { continue }
            let key = token[..<eq]
            let value = String(token[token.index(after: eq)...])
            switch key {
            case "id": id = value
            case "part": part = MeetingPart(rawValue: value)
            default: continue
            }
        }
        guard let id = id.flatMap(canonicalId), let part else { return nil }
        return Header(meetingId: id, part: part)
    }

    /// Reads just the head of a relay file and parses its marker. Cheap enough
    /// to run on every relay candidate before any ledger decision.
    nonisolated static func peek(fileAt url: URL) -> Header? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: peekBytes), !data.isEmpty else { return nil }
        return parse(String(decoding: data, as: UTF8.self))?.header
    }

    /// The canonical form of an id: a UUID in Foundation's uppercase spelling,
    /// so `abc…` and `ABC…` name the same meeting. Anything else must be a short
    /// token of letters, digits, and dashes (it lands in YAML front matter and in
    /// state.json, so no spaces, colons, or quotes).
    nonisolated static func canonicalId(_ raw: String) -> String? {
        if let uuid = UUID(uuidString: raw) { return uuid.uuidString }
        guard !raw.isEmpty, raw.count <= maxIdLength,
              raw.unicodeScalars.allSatisfy({ ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" })
        else { return nil }
        return raw
    }

    /// The `# <title>` line at the top of a meeting body, sanitized for a
    /// filename (iOS writes "Meeting, Sep 29, 2:30 PM"; the colon must go).
    /// Fallback title source when the relay filename carries none.
    nonisolated static func headingTitle(of body: String) -> String? {
        let firstLine = body.prefix(while: { !$0.isNewline })
        guard firstLine.hasPrefix("# ") else { return nil }
        return TitleDeriver.enrichedLinkTitle(from: String(firstLine.dropFirst(2)))
    }
}
