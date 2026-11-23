import Foundation

/// The enrichment fetch seam. Tests inject `FakeLinkFetcher`; the app uses
/// `URLSessionLinkFetcher`. Everything behind this protocol is best-effort:
/// throw a `LinkFetchError` and the service's retry/give-up policy decides.
@MainActor
protocol LinkFetching: AnyObject, Sendable {
    /// Real title (oEmbed) + plain-paragraph transcript (caption endpoints).
    func fetchYouTube(videoID: String) async throws -> FetchedLinkContent
    /// Real title (og:title/<title>) + readability-style text extraction.
    func fetchArticle(url: URL) async throws -> FetchedLinkContent
    /// A public Facebook, Instagram, Threads or X post: the post text (first
    /// line as the title) and whether it carries a video. A login wall, a
    /// private or removed post, or empty text throws `.unusableContent`.
    func fetchSocialPost(url: URL, platform: SocialPost.Platform) async throws -> FetchedLinkContent
}
