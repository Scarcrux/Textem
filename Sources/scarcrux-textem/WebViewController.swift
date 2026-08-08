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
    // Retain live popup windows (e.g. the Google verification popup) so they
    // aren't deallocated mid-flow.
    private var popups: [PopupWindowController] = []
    // Drives the dock badge + new-message notifications off the page title.
    private var titleObservation: NSKeyValueObservation?
    private var lastUnreadCount = 0

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        // Persistent store: keeps the pairing/session (and Google cookies)
        // across launches so you don't re-authenticate every time.
        let dataStore = WKWebsiteDataStore.default()
        configuration.websiteDataStore = dataStore
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true

        // Disable Intelligent Tracking Prevention on the data store. WKWebView
        // partitions/blocks cross-site cookies by default, which severs
        // Google's shared login between accounts.google.com and
        // messages.google.com — the page can't read its own freshly-set
        // session, so it re-challenges endlessly and device pairing never
        // registers. Private WebKit API (fine for a Developer-ID app, not the
        // App Store); passing `nil` sends a null pointer = BOOL NO = disabled.
        let disableITP = NSSelectorFromString("_setResourceLoadStatisticsEnabled:")
        if dataStore.responds(to: disableITP) {
            dataStore.perform(disableITP, with: nil)
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.desktopUserAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // Allow attaching Safari's Web Inspector (Develop > Textem) to debug
        // the sign-in/verification flow.
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }

        // Google puts the unread count in the document title, e.g.
        // "(3) Messages". Observe it to drive the badge/notifications without
        // scraping the DOM.
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] _, change in
            // Read the title from the change (Sendable) and hop to the main
            // actor rather than touching the isolated webView.title here.
            let newTitle = change.newValue ?? nil
            Task { @MainActor in self?.handleTitleChange(newTitle) }
        }

        self.webView = webView
        self.view = webView
    }

    private func handleTitleChange(_ title: String?) {
        let count = Self.parseUnreadCount(from: title)
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil

        // Notify only when the count rises and Textem isn't the active app —
        // no point pinging you about a thread you're already looking at.
        if count > lastUnreadCount, !NSApp.isActive {
            NotificationManager.shared.notifyNewMessages(newCount: count - lastUnreadCount)
        }
        lastUnreadCount = count
    }

    // Pull the integer out of a leading "(N)" in the title; 0 if absent.
    static func parseUnreadCount(from title: String?) -> Int {
        guard let title,
              let open = title.firstIndex(of: "("),
              let close = title[open...].firstIndex(of: ")") else { return 0 }
        let inner = title[title.index(after: open)..<close]
        return Int(inner) ?? 0
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.load(URLRequest(url: Self.messagesURL))
    }

    // Reachable via the View > Reload menu item (⌘R) through the responder
    // chain. Needed to pick up device pairing after completing it on the phone.
    @objc func reloadPage(_ sender: Any?) {
        webView.reload()
    }

    // Hard reload back to the messages entry point (⇧⌘R) for when the session
    // is wedged and a plain reload won't recover it.
    @objc func reloadFromOrigin(_ sender: Any?) {
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
    // window.open / target="_blank": keep it in-app as a child webview so
    // popup-based flows (Google account/passcode verification) can postMessage
    // back to their opener. A plain external link with no opener dependency
    // is routed to the default browser instead.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = PopupWindowController(configuration: configuration) { [weak self] controller in
            self?.popups.removeAll { $0 === controller }
        }
        popups.append(popup)
        popup.showWindow(nil)
        popup.window?.makeKeyAndOrderFront(nil)
        return popup.webView
    }
}
