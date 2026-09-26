import AppKit
import WebKit

// Hosts a `window.open` popup in an in-app child WKWebView.
//
// Google's account/passcode verification opens a popup against
// accounts.google.com and completes the handshake by postMessage-ing back
// to `window.opener`. Routing that popup to the external browser (as the
// naive uiDelegate did) severs the opener link and the page stalls waiting
// for a confirmation that now happens in Safari. Keeping it in-app — using
// the exact configuration WebKit hands us, which shares the process pool
// and data store — preserves the opener relationship.
final class PopupWindowController: NSWindowController {
    let webView: WKWebView
    private let onClose: (PopupWindowController) -> Void

    init(configuration: WKWebViewConfiguration,
         onClose: @escaping (PopupWindowController) -> Void) {
        // Must build the popup from the passed-in configuration, per the
        // WKUIDelegate contract, so it shares state with the opener.
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = WebViewController.desktopUserAgent
        #if DEBUG
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        #endif
        self.webView = webView
        self.onClose = onClose

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in"
        window.center()
        window.contentView = webView

        super.init(window: window)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

extension PopupWindowController: WKUIDelegate {
    // The popup itself may call window.close() when the flow finishes.
    func webViewDidClose(_ webView: WKWebView) {
        close()
    }
}

extension PopupWindowController: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let isEmbeddedFrame = navigationAction.targetFrame?.isMainFrame == false
        let isAllowed = isEmbeddedFrame
            ? WebNavigationPolicy.isAllowedEmbeddedURL(url)
            : WebNavigationPolicy.isAllowedTopLevelURL(url)
        guard isAllowed else {
            if let url = navigationAction.request.url,
               navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}

extension PopupWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        onClose(self)
    }
}
