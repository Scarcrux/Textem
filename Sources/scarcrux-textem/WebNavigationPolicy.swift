import Foundation

// The web view carries a signed-in Google session and has no address bar, so
// navigation is an explicit trust boundary. A suffix such as "google.com" is
// not sufficient: attacker-controlled names like "notgoogle.com" also match.
enum WebNavigationPolicy {
    private static let embeddedDomains = [
        "google.com",
        "gstatic.com",
        "googleusercontent.com",
    ]

    static func isAllowedTopLevelURL(_ url: URL) -> Bool {
        if isEmptyAboutPage(url) { return true }
        guard isHTTPS(url), let host = url.host?.lowercased() else { return false }
        // gstatic and googleusercontent serve resources/user content; neither
        // needs to become the address-bar-less top-level application page.
        return Self.host(host, isWithin: "google.com")
    }

    static func isAllowedEmbeddedURL(_ url: URL) -> Bool {
        if isEmptyAboutPage(url) { return true }
        guard isHTTPS(url), let host = url.host?.lowercased() else { return false }
        return embeddedDomains.contains { Self.host(host, isWithin: $0) }
    }

    static func isAllowedBridgeOrigin(scheme: String, host: String) -> Bool {
        scheme.lowercased() == "https" && host.lowercased() == "messages.google.com"
    }

    private static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
    }

    private static func isEmptyAboutPage(_ url: URL) -> Bool {
        url.scheme == "about" && url.absoluteString == "about:blank"
    }

    private static func host(_ host: String, isWithin domain: String) -> Bool {
        host == domain || host.hasSuffix(".\(domain)")
    }
}
