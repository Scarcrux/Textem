import AppKit
import WebKit

final class WebViewController: NSViewController {
    // The web client. Google gates this on the User-Agent; a mobile or
    // unrecognized UA gets a degraded page or a refusal.
    private static let messagesURL = URL(string: "https://messages.google.com/web/")!

    // Present as desktop Safari. This is the single most load-bearing line
    // in the whole spike — without it Google may not serve the full client,
    // and it's our first lever if the new account sign-in gets blocked as
    // an "insecure browser".
    private static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    private var webView: WKWebView!

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        // Persistent store: keeps the pairing/session (and Google cookies)
        // across launches so you don't re-authenticate every time.
        configuration.websiteDataStore = .default()
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.desktopUserAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        webView.uiDelegate = self

        self.webView = webView
        self.view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.load(URLRequest(url: Self.messagesURL))
    }

    // Keep Google/Messages hosts inside the app; send everything else to the
    // user's default browser (avoids opening random links in the shell).
    private func isInternal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.hasSuffix("google.com")
            || host.hasSuffix("gstatic.com")
            || host.hasSuffix("googleusercontent.com")
    }
}

extension WebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // Externally-triggered navigations to non-Google hosts open in Safari.
        if navigationAction.navigationType == .linkActivated, !isInternal(url) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

extension WebViewController: WKUIDelegate {
    // Handle target="_blank" / window.open by routing to the default browser
    // rather than silently dropping the click.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
        }
        return nil
    }
}
