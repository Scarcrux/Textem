import XCTest
@testable import scarcrux_textem

final class WebNavigationPolicyTests: XCTestCase {
    func testAllowsGoogleTopLevelPagesOverHTTPS() {
        XCTAssertTrue(topLevelAllowed("https://messages.google.com/web/"))
        XCTAssertTrue(topLevelAllowed("https://accounts.google.com/signin"))
    }

    func testResourceDomainsAreEmbeddedOnly() {
        XCTAssertTrue(embeddedAllowed("https://ssl.gstatic.com/example"))
        XCTAssertTrue(embeddedAllowed("https://lh3.googleusercontent.com/example"))
        XCTAssertFalse(topLevelAllowed("https://ssl.gstatic.com/example"))
        XCTAssertFalse(topLevelAllowed("https://lh3.googleusercontent.com/example"))
    }

    func testRejectsLookalikeDomains() {
        XCTAssertFalse(topLevelAllowed("https://evilgoogle.com/"))
        XCTAssertFalse(topLevelAllowed("https://google.com.example.org/"))
        XCTAssertFalse(embeddedAllowed("https://gstatic.com.example.org/"))
    }

    func testRejectsNonHTTPSAndExecutableSchemes() {
        XCTAssertFalse(topLevelAllowed("http://messages.google.com/web/"))
        XCTAssertFalse(topLevelAllowed("javascript:alert(1)"))
        XCTAssertFalse(topLevelAllowed("file:///tmp/example"))
    }

    func testAllowsOnlyEmptyAboutPage() {
        XCTAssertTrue(topLevelAllowed("about:blank"))
        XCTAssertFalse(topLevelAllowed("about:srcdoc"))
    }

    func testBridgeIsRestrictedToMessagesOrigin() {
        XCTAssertTrue(WebNavigationPolicy.isAllowedBridgeOrigin(
            scheme: "https", host: "messages.google.com"))
        XCTAssertFalse(WebNavigationPolicy.isAllowedBridgeOrigin(
            scheme: "https", host: "accounts.google.com"))
        XCTAssertFalse(WebNavigationPolicy.isAllowedBridgeOrigin(
            scheme: "http", host: "messages.google.com"))
    }

    private func topLevelAllowed(_ raw: String) -> Bool {
        guard let url = URL(string: raw) else { return false }
        return WebNavigationPolicy.isAllowedTopLevelURL(url)
    }

    private func embeddedAllowed(_ raw: String) -> Bool {
        guard let url = URL(string: raw) else { return false }
        return WebNavigationPolicy.isAllowedEmbeddedURL(url)
    }
}
