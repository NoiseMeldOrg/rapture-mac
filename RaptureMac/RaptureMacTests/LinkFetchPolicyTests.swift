import XCTest
@testable import Rapture

/// SSRF guard for the article fetch path. `LinkFetchPolicy` is pure, so these
/// run with no network and no fetcher instance.
final class LinkFetchPolicyTests: XCTestCase {

    private func fetchable(_ string: String) -> Bool {
        guard let url = URL(string: string) else { return false }
        return LinkFetchPolicy.isFetchable(url)
    }

    // MARK: - Allowed: ordinary public http(s), including public IPs

    func testPublicHTTPSIsFetchable() {
        XCTAssertTrue(fetchable("https://example.com"))
        XCTAssertTrue(fetchable("https://www.paulgraham.com/greatwork.html"))
        XCTAssertTrue(fetchable("http://example.com/path?q=1&x=2"))
        XCTAssertTrue(fetchable("https://news.ycombinator.com/item?id=1"))
    }

    func testPublicIPsAreFetchable() {
        XCTAssertTrue(fetchable("http://8.8.8.8/"))
        // Just outside the private ranges — must NOT be blocked.
        XCTAssertTrue(fetchable("http://172.15.0.1/"))   // below 172.16/12
        XCTAssertTrue(fetchable("http://172.32.0.1/"))   // above 172.16/12
        XCTAssertTrue(fetchable("http://192.169.0.1/"))  // not 192.168
        XCTAssertTrue(fetchable("http://11.0.0.1/"))     // not 10/8
    }

    // MARK: - Blocked: non-http(s) schemes

    func testNonHTTPSchemesAreBlocked() {
        XCTAssertFalse(fetchable("file:///etc/passwd"))
        XCTAssertFalse(fetchable("ftp://example.com/x"))
        XCTAssertFalse(fetchable("data:text/html,<h1>x</h1>"))
        XCTAssertFalse(fetchable("javascript:alert(1)"))
        XCTAssertFalse(fetchable("about:blank"))
        XCTAssertFalse(fetchable("mailto:a@b.com"))
    }

    func testSchemeIsCaseInsensitive() {
        XCTAssertTrue(fetchable("HTTPS://example.com"))
        XCTAssertTrue(fetchable("HtTp://example.com"))
    }

    // MARK: - Blocked: loopback / localhost / mDNS

    func testLoopbackAndLocalhostBlocked() {
        XCTAssertFalse(fetchable("http://localhost/"))
        XCTAssertFalse(fetchable("http://localhost:8080/admin"))
        XCTAssertFalse(fetchable("http://LOCALHOST/"))
        XCTAssertFalse(fetchable("http://foo.localhost/"))
        XCTAssertFalse(fetchable("http://mymac.local/"))
        XCTAssertFalse(fetchable("http://127.0.0.1/"))
        XCTAssertFalse(fetchable("http://127.5.9.200:9000/"))
    }

    // MARK: - Blocked: private / link-local IPv4

    func testPrivateAndLinkLocalIPv4Blocked() {
        XCTAssertFalse(fetchable("http://10.0.0.1/"))
        XCTAssertFalse(fetchable("http://10.255.255.254/"))
        XCTAssertFalse(fetchable("http://172.16.0.1/"))
        XCTAssertFalse(fetchable("http://172.31.255.255/"))
        XCTAssertFalse(fetchable("http://172.20.5.5/"))
        XCTAssertFalse(fetchable("http://192.168.1.1/"))
        XCTAssertFalse(fetchable("http://169.254.169.254/"))  // link-local (cloud-metadata shape)
        XCTAssertFalse(fetchable("http://0.0.0.0/"))
    }

    // MARK: - Blocked: IPv6 loopback / link-local / unique-local

    func testPrivateIPv6Blocked() {
        XCTAssertFalse(fetchable("http://[::1]/"))
        XCTAssertFalse(fetchable("http://[fe80::1]/"))
        XCTAssertFalse(fetchable("http://[fc00::1]/"))
        XCTAssertFalse(fetchable("http://[fd12:3456::1]/"))
    }

    // MARK: - Blocked: malformed / no host / no scheme

    func testMissingSchemeOrHostBlocked() {
        XCTAssertFalse(fetchable("//example.com"))       // scheme-relative
        XCTAssertFalse(fetchable("example.com/path"))    // no scheme
        XCTAssertFalse(fetchable("https://"))            // no host
    }
}
