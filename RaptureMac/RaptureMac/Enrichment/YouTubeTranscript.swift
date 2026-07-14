import Foundation

/// Pure parsers for the unofficial YouTube caption flow — explicitly
/// best-effort and expected to break occasionally (the quiet-failure posture is
/// the designed-for outcome). All I/O lives in `URLSessionLinkFetcher`; every
/// function here is bytes-in/values-out and golden-tested.
enum YouTubeTranscript {

    struct CaptionTrack: Equatable, Sendable {
        var baseUrl: String
        var languageCode: String
        /// `"asr"` marks an auto-generated track.
        var kind: String?
    }

    // MARK: - Watch-page HTML → player response

    /// Extracts the `ytInitialPlayerResponse` JSON object from watch-page HTML
    /// via brace-balanced scanning (the object is a script-embedded literal;
    /// regex-to-end-of-line is not reliable). nil when the marker is missing.
    nonisolated static func extractPlayerResponseJSON(fromWatchHTML html: String) -> Data? {
        guard let markerRange = html.range(of: "ytInitialPlayerResponse") else { return nil }
        guard let braceIndex = html[markerRange.upperBound...].firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        var index = braceIndex
        while index < html.endIndex {
            let ch = html[index]
            if escaped {
                escaped = false
            } else if inString {
                if ch == "\\" { escaped = true }
                if ch == "\"" { inString = false }
            } else {
                switch ch {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        let json = String(html[braceIndex...index])
                        return Data(json.utf8)
                    }
                default: break
                }
            }
            index = html.index(after: index)
        }
        return nil
    }

    // MARK: - Player response → caption tracks

    /// Works for both the watch-page-embedded object and the innertube
    /// `/youtubei/v1/player` response (same shape).
    nonisolated static func captionTracks(fromPlayerResponse data: Data) -> [CaptionTrack] {
        struct PlayerResponse: Decodable {
            struct Captions: Decodable {
                struct TracklistRenderer: Decodable {
                    struct Track: Decodable {
                        let baseUrl: String
                        let languageCode: String
                        let kind: String?
                    }
                    let captionTracks: [Track]?
                }
                let playerCaptionsTracklistRenderer: TracklistRenderer?
            }
            let captions: Captions?
        }
        guard let response = try? JSONDecoder().decode(PlayerResponse.self, from: data),
              let tracks = response.captions?.playerCaptionsTracklistRenderer?.captionTracks
        else { return [] }
        return tracks.map { CaptionTrack(baseUrl: $0.baseUrl, languageCode: $0.languageCode, kind: $0.kind) }
    }

    /// Manual English > auto-generated (ASR) English > first track of any kind.
    nonisolated static func pickTrack(_ tracks: [CaptionTrack]) -> CaptionTrack? {
        let english = tracks.filter { $0.languageCode.lowercased().hasPrefix("en") }
        if let manual = english.first(where: { $0.kind != "asr" }) { return manual }
        if let asr = english.first { return asr }
        return tracks.first
    }

    // MARK: - json3 caption payload → plain paragraphs

    /// Break a paragraph when the gap between caption events exceeds this, or
    /// when the running paragraph passes `paragraphSoftCap` characters.
    nonisolated static let paragraphGapMs = 4_000
    nonisolated static let paragraphSoftCap = 700

    /// Joins json3 caption segments into flowing plain-text paragraphs
    /// (timestamps discarded — locked user decision). nil when the payload has
    /// no usable text.
    nonisolated static func transcriptMarkdown(fromJSON3 data: Data) -> String? {
        struct Payload: Decodable {
            struct Event: Decodable {
                struct Seg: Decodable { let utf8: String? }
                let tStartMs: Int?
                let segs: [Seg]?
            }
            let events: [Event]?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let events = payload.events
        else { return nil }

        var paragraphs: [String] = []
        var current = ""
        var lastStart: Int?

        for event in events {
            guard let segs = event.segs else { continue }
            let text = segs.compactMap(\.utf8).joined()
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            let gapExceeded: Bool
            if let start = event.tStartMs, let last = lastStart {
                gapExceeded = start - last > paragraphGapMs
            } else {
                gapExceeded = false
            }
            if !current.isEmpty && (gapExceeded || current.count > paragraphSoftCap) {
                paragraphs.append(current)
                current = ""
            }
            current = current.isEmpty ? text : current + " " + text
            lastStart = event.tStartMs ?? lastStart
        }
        if !current.isEmpty { paragraphs.append(current) }

        let joined = paragraphs.joined(separator: "\n\n")
        return joined.isEmpty ? nil : joined
    }

    // MARK: - Innertube request (the primary caption-track source)

    /// The iOS client context: verified live (2026-07-13), it returns playable
    /// caption tracks whose URLs serve real json3 bodies. The WEB client comes
    /// back UNPLAYABLE with zero tracks, and the watch page's embedded caption
    /// URLs return 200-with-empty-body without a proof-of-origin token — which
    /// is why iOS is primary and the watch page is only a fallback.
    nonisolated static let innertubeClientVersion = "20.10.4"
    nonisolated static let innertubeUserAgent =
        "com.google.ios.youtube/\(innertubeClientVersion) (iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X)"

    /// Request body for `POST youtubei/v1/player` with the iOS client context.
    nonisolated static func innertubeRequestBody(videoID: String) -> Data {
        let body: [String: Any] = [
            "videoId": videoID,
            "context": [
                "client": [
                    "clientName": "IOS",
                    "clientVersion": innertubeClientVersion
                ]
            ]
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    // MARK: - oEmbed title

    /// The one stable, public, no-key endpoint in the flow — used for the real
    /// title so the rename works even when the caption fetch fails.
    nonisolated static func title(fromOEmbedJSON data: Data) -> String? {
        struct OEmbed: Decodable { let title: String? }
        let title = (try? JSONDecoder().decode(OEmbed.self, from: data))?.title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else { return nil }
        return title
    }
}
