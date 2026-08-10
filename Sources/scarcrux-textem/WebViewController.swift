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
    // Latest unread count reported by the JS bridge.
    private var lastUnreadCount = 0
    // Notified whenever the unread count changes (drives the menu-bar item).
    var onUnreadCountChanged: ((Int) -> Void)?
    // The account's isolated session store.
    private let dataStore: WKWebsiteDataStore

    init(dataStore: WKWebsiteDataStore) {
        self.dataStore = dataStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let configuration = WKWebViewConfiguration()
        // Persistent store (per account): keeps the pairing/session across
        // relaunches so you don't re-authenticate every time.
        configuration.websiteDataStore = dataStore
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true

        // Install the unread-count bridge (JS -> native message handler).
        // Weak proxy avoids a retain cycle so we can free this VC on switch.
        let controller = configuration.userContentController
        controller.add(WeakScriptMessageHandler(self), name: WebBridge.handlerName)
        controller.addUserScript(WKUserScript(
            source: WebBridge.userScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

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

        self.webView = webView
        self.view = webView
    }

    // Called from the JS bridge with the current unread count.
    private func handleUnread(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil

        // Notify only when the count rises, Textem isn't active, and
        // notifications aren't muted.
        if count > lastUnreadCount, !NSApp.isActive, !Preferences.notificationsMuted {
            NotificationManager.shared.notifyNewMessages(newCount: count - lastUnreadCount)
        }
        lastUnreadCount = count
        onUnreadCountChanged?(count)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.load(URLRequest(url: Self.messagesURL))
    }

    // Detach the web view before this controller is replaced (account switch)
    // so it stops loading, drops the bridge handler, and can deallocate.
    func teardown() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.removeScriptMessageHandler(forName: WebBridge.handlerName)
    }

    // Reachable via the View > Reload menu item (⌘R) through the responder
    // chain. Needed to pick up device pairing after completing it on the phone.
    @objc func reloadPage(_ sender: Any?) {
        webView.reload()
    }

    // MARK: Zoom (⌘+ / ⌘- / ⌘0) — a Texty Pro feature, free here.

    @objc func zoomIn(_ sender: Any?) { setZoom(Preferences.zoom + 0.1) }
    @objc func zoomOut(_ sender: Any?) { setZoom(Preferences.zoom - 0.1) }
    @objc func zoomReset(_ sender: Any?) { setZoom(1.0) }

    private func setZoom(_ factor: Double) {
        let clamped = min(2.0, max(0.5, (factor * 10).rounded() / 10))
        Preferences.zoom = clamped
        applyZoom()
    }

    private func applyZoom() {
        let factor = Preferences.zoom
        if #available(macOS 14.0, *) {
            webView.pageZoom = factor
        } else {
            // CSS-zoom fallback for macOS 13; re-applied after each load.
            webView.evaluateJavaScript("document.documentElement.style.zoom='\(factor)'", completionHandler: nil)
        }
    }

    // Toggle keep-window-above-others (Caprine parity).
    @objc func toggleAlwaysOnTop(_ sender: NSMenuItem) {
        guard let window = view.window else { return }
        let on = sender.state != .on
        window.level = on ? .floating : .normal
        sender.state = on ? .on : .off
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        applyZoom()
    }
}

extension WebViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                              didReceive message: WKScriptMessage) {
        guard message.name == WebBridge.handlerName,
              let body = message.body as? [String: Any],
              body["type"] as? String == "unread" else { return }
        let count = (body["count"] as? Int) ?? (body["count"] as? NSNumber)?.intValue ?? 0
        handleUnread(count)
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
