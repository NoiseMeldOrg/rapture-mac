import Foundation

/// Decides whether a URL is safe for link enrichment to fetch. The article path
/// GETs a URL taken verbatim from a capture, so without this a crafted captured
/// link could point the app at a loopback/private address (blind SSRF). Pure and
/// nonisolated so it's unit-tested without the network or the @MainActor fetcher.
///
/// Scope (deliberately proportionate to a personal-Mac threat model):
///   - Allow only `http`/`https`. Everything else (`file`, `ftp`, `data`,
///     `javascript`, scheme-relative, …) is refused.
///   - Refuse host *literals* in loopback / private / link-local ranges.
///
/// Out of scope, accepted as residual: resolve-time pinning against DNS
/// rebinding, and redirect-following to a private host (the HTTP client follows
/// redirects) — both are dynamic vectors, and the payload here is blind (the
/// response lands in the user's own vault, never back to an attacker), so the
/// value of those attacks is low. The static literal guard closes the realistic
/// case (a direct `http://localhost:…` / `http://10.x` capture) at near-zero cost.
enum LinkFetchPolicy {
    static let allowedSchemes: Set<String> = ["http", "https"]

    /// True when enrichment may fetch `url`. A blocked URL should surface as a
    /// content-class give-up (`LinkFetchError.blockedURL`) so the note stays as
    /// filed with no retry.
    static func isFetchable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else {
            return false
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return !isBlockedHost(host)
    }

    /// Loopback / private / link-local host literals. Bare hostnames that only
    /// *resolve* to such addresses are not caught here (that's the out-of-scope
    /// resolve-time case).
    static func isBlockedHost(_ host: String) -> Bool {
        // localhost and mDNS `.local`
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return true
        }
        // IPv6 literals (URL.host strips the brackets): loopback, link-local,
        // unique-local. Rough prefix match — enough for the realistic cases.
        if host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") {
            return true
        }
        // IPv4 literals in loopback / private / link-local / unspecified ranges.
        if let octets = ipv4Octets(host) {
            return isPrivateOrLoopbackV4(octets)
        }
        return false
    }

    /// Parses a dotted-quad into 4 in-range octets, or nil if `host` isn't an
    /// IPv4 literal (e.g. a real hostname — left for DNS to resolve, not blocked).
    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let n = Int(part), (0...255).contains(n) else {
                return nil
            }
            octets.append(n)
        }
        return octets
    }

    private static func isPrivateOrLoopbackV4(_ o: [Int]) -> Bool {
        switch (o[0], o[1]) {
        case (0, _):            return true   // 0.0.0.0/8   unspecified / this-host
        case (127, _):          return true   // 127.0.0.0/8 loopback
        case (10, _):           return true   // 10.0.0.0/8  private
        case (172, 16...31):    return true   // 172.16.0.0/12 private
        case (192, 168):        return true   // 192.168.0.0/16 private
        case (169, 254):        return true   // 169.254.0.0/16 link-local
        default:                return false
        }
    }
}
