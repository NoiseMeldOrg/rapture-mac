import Foundation
import OSLog

/// The link-enrichment fetcher — with `TriageAI/AnthropicEngine.swift`, one of
/// the only places in the app that performs an outbound network request besides
/// Sparkle (PRIVACY.md names this file; keep it that way). Runs only when the
/// user turned link enrichment on and a link capture just filed. Front-guarded
/// on XCTest so the hosted test suite can never reach the network. Only the
/// captured URL (and, for YouTube, its video ID) is ever sent — never note text.
@MainActor
final class URLSessionLinkFetcher: LinkFetching {
    nonisolated static let log = Logger(subsystem: "noisemeld.RaptureMac", category: "URLSessionLinkFetcher")

    /// Per-request ceiling; the service additionally races the whole attempt.
    nonisolated static let requestTimeout: TimeInterval = 10
    /// Responses beyond this are not articles worth extracting (content-class give-up).
    nonisolated static let maxResponseBytes = 5 * 1024 * 1024
    /// Caption endpoints and some article hosts shape responses by UA; present as a browser.
    nonisolated static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    // MARK: - YouTube

    func fetchYouTube(videoID: String) async throws -> FetchedLinkContent {
        guard !ProcessInfo.processInfo.isRunningXCTests else { throw LinkFetchError.unavailable }

        let watchURL = "https://www.youtube.com/watch?v=\(videoID)"

        // Title first, via the stable public oEmbed endpoint — best-effort on
        // its own: a failed title never blocks the transcript (and vice versa).
        var title: String?
        if let oembedURL = URL(string: "https://www.youtube.com/oembed?url=\(watchURL)&format=json"),
           let (data, status) = try? await get(oembedURL), status == 200 {
            title = YouTubeTranscript.title(fromOEmbedJSON: data)
        }

        // Primary: innertube with the iOS client (see YouTubeTranscript's note —
        // the watch page's embedded caption URLs serve empty bodies these days).
        let tracks = try await innertubeCaptionTracks(videoID: videoID)
        if let transcript = try await transcript(fromTracks: tracks) {
            return FetchedLinkContent(title: title, bodyMarkdown: transcript)
        }

        // Fallback: the watch-page embed, in case the innertube contract drifts.
        // Failures here are content-class by definition — the primary already
        // ran, so both failing quietly is the designed-for outcome.
        if let watchTracks = try? await watchPageCaptionTracks(watchURL: watchURL),
           let transcript = try? await transcript(fromTracks: watchTracks) {
            return FetchedLinkContent(title: title, bodyMarkdown: transcript)
        }
        throw LinkFetchError.noCaptions
    }

    /// Picks a track, fetches its json3 payload, joins it into paragraphs.
    /// nil = no usable track/text (content-class); throws = transport trouble.
    private func transcript(fromTracks tracks: [YouTubeTranscript.CaptionTrack]) async throws -> String? {
        guard let track = YouTubeTranscript.pickTrack(tracks) else { return nil }
        let separator = track.baseUrl.contains("?") ? "&" : "?"
        guard let captionURL = URL(string: track.baseUrl + separator + "fmt=json3") else { return nil }
        let (data, status) = try await get(captionURL)
        guard status == 200 else { throw LinkFetchError.http(status) }
        return YouTubeTranscript.transcriptMarkdown(fromJSON3: data)
    }

    private func innertubeCaptionTracks(videoID: String) async throws -> [YouTubeTranscript.CaptionTrack] {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false") else { return [] }
        var request = makeRequest(url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(YouTubeTranscript.innertubeUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = YouTubeTranscript.innertubeRequestBody(videoID: videoID)
        let (data, status) = try await perform(request)
        guard status == 200 else { throw LinkFetchError.http(status) }
        return await Task.detached(priority: .utility) {
            YouTubeTranscript.captionTracks(fromPlayerResponse: data)
        }.value
    }

    private func watchPageCaptionTracks(watchURL: String) async throws -> [YouTubeTranscript.CaptionTrack] {
        guard let watch = URL(string: watchURL) else { return [] }
        let (data, status) = try await get(watch)
        guard status == 200 else { return [] }
        let html = Self.decodeBody(data, textEncodingName: nil)
        return await Task.detached(priority: .utility) {
            guard let json = YouTubeTranscript.extractPlayerResponseJSON(fromWatchHTML: html) else { return [] }
            return YouTubeTranscript.captionTracks(fromPlayerResponse: json)
        }.value
    }

    // MARK: - Articles

    func fetchArticle(url: URL) async throws -> FetchedLinkContent {
        guard !ProcessInfo.processInfo.isRunningXCTests else { throw LinkFetchError.unavailable }
        // The article URL comes verbatim from a capture; refuse non-http(s) and
        // loopback/private host literals before we ever open a socket (SSRF).
        guard LinkFetchPolicy.isFetchable(url) else { throw LinkFetchError.blockedURL }

        let (data, status, encodingName) = try await getWithEncoding(url)
        guard status == 200 else { throw LinkFetchError.http(status) }
        let html = Self.decodeBody(data, textEncodingName: encodingName)

        // Multi-MB regex passes must not block the main actor (TriageProcessor's
        // detached-read precedent).
        let extracted = await Task.detached(priority: .utility) {
            (title: ArticleExtractor.title(fromHTML: html), body: ArticleExtractor.readableText(fromHTML: html))
        }.value
        guard let body = extracted.body else { throw LinkFetchError.unusableContent }
        return FetchedLinkContent(title: extracted.title, bodyMarkdown: body)
    }

    // MARK: - Transport

    private func get(_ url: URL) async throws -> (Data, Int) {
        try await perform(makeRequest(url))
    }

    private func getWithEncoding(_ url: URL) async throws -> (Data, Int, String?) {
        let (data, response) = try await send(makeRequest(url))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        try Self.checkSize(data)
        return (data, status, response.textEncodingName)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        try Self.checkSize(data)
        return (data, status)
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw LinkFetchError.timeout
        } catch {
            throw LinkFetchError.network(error.localizedDescription)
        }
    }

    private func makeRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeout
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        return request
    }

    private nonisolated static func checkSize(_ data: Data) throws {
        guard data.count <= maxResponseBytes else { throw LinkFetchError.unusableContent }
    }

    /// Charset from the HTTP response when stated; UTF-8 (lossy) otherwise.
    nonisolated static func decodeBody(_ data: Data, textEncodingName: String?) -> String {
        if let name = textEncodingName {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                let ns = CFStringConvertEncodingToNSStringEncoding(cf)
                if let decoded = String(data: data, encoding: String.Encoding(rawValue: ns)) {
                    return decoded
                }
            }
        }
        return String(decoding: data, as: UTF8.self)
    }
}
