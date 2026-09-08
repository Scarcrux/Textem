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
    // Find-in-page overlay (⌘F).
    private var findBar: FindBar!
    // Load-failure recovery. WKWebView paints a FAILED navigation as a blank
    // white page and reports nothing on its own, so without this a transient
    // fault (offline at login, sleep/wake, DNS blip) strands the user on a white
    // window forever. Retry with backoff, then surface a real error.
    private var errorView: LoadErrorView!
    // Text of an in-flight inline reply, so a failure can hand it back to the
    // user instead of losing what they typed.
    private var pendingReplyText: String?
    private var loadRetryCount = 0
    private var loadRetryTask: Task<Void, Never>?
    private static let maxLoadRetries = 5

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

        // Container hosts the web view plus a hidden find bar pinned to the top.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 820))
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)

        let bar = FindBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.isHidden = true
        bar.onFind = { [weak self] query, backwards in self?.find(query, backwards: backwards) }
        bar.onClose = { [weak self] in self?.closeFind() }
        container.addSubview(bar)
        findBar = bar

        // Covers the web view only when a load has definitively failed.
        let errorView = LoadErrorView()
        errorView.translatesAutoresizingMaskIntoConstraints = false
        errorView.isHidden = true
        errorView.onRetry = { [weak self] in self?.retryLoadNow() }
        container.addSubview(errorView)
        self.errorView = errorView

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            errorView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            errorView.topAnchor.constraint(equalTo: container.topAnchor),
            errorView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        self.view = container
    }

    // MARK: Find in page (⌘F / ⌘G / ⇧⌘G)

    @objc func performFind(_ sender: Any?) {
        findBar.isHidden = false
        findBar.focus()
    }

    @objc func findNext(_ sender: Any?) { find(findBar.query, backwards: false) }
    @objc func findPrevious(_ sender: Any?) { find(findBar.query, backwards: true) }

    private func find(_ query: String, backwards: Bool) {
        guard !query.isEmpty else { return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.caseSensitive = false
        config.wraps = true
        webView.find(query, configuration: config, completionHandler: { _ in })
    }

    private func closeFind() {
        findBar.isHidden = true
        webView.evaluateJavaScript("window.getSelection && window.getSelection().removeAllRanges()", completionHandler: nil)
        view.window?.makeFirstResponder(webView)
    }

    // Called from the JS bridge with the current unread count (+ optional
    // sender/snippet of the newest unread conversation).
    private func handleUnread(_ count: Int, sender: String?, snippet: String?, convId: String?) {
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil

        // Notify only when the count rises, Textem isn't active, and
        // notifications aren't muted.
        if count > lastUnreadCount, !NSApp.isActive, !Preferences.notificationsMuted {
            NotificationManager.shared.notifyNewMessages(
                newCount: count - lastUnreadCount, sender: sender, snippet: snippet, convId: convId)
        }
        lastUnreadCount = count
        onUnreadCountChanged?(count)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.load(URLRequest(url: Self.messagesURL))
        // Diagnostic (TEXTEM_SELFCHECK=1): dump web-view state to a file shortly
        // after launch. Screen recording + accessibility are denied to tooling on
        // this machine, so this is how a "blank window" report becomes an actual
        // cause instead of a guess. Off unless explicitly enabled.
        if ProcessInfo.processInfo.environment["TEXTEM_SELFCHECK"] == "1" { scheduleSelfCheck() }
        // Re-apply privacy CSS when a toggle changes at runtime.
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyPrivacyCSS),
            name: Preferences.privacyChanged, object: nil
        )
    }

    // Inline reply from a notification: open the newest unread conversation,
    // type the text, and send. Best-effort DOM automation — composer/send
    // selectors are heuristic and need a live message to fully verify.
    // Inline reply from a notification.
    //
    // Targets the EXACT conversation the notification was for, via
    // data-e2e-conversation (confirmed present on the live DOM). The previous
    // implementation replied to the "first unread" row, which meant a message
    // arriving between notification and reply could send your text to the WRONG
    // person. If the target row isn't found we now FAIL rather than guess.
    //
    // Polls for the composer and send button instead of racing fixed delays,
    // and reports the outcome so a failed reply surfaces instead of vanishing.
    func quickReply(_ text: String, convId: String?) {
        guard let textData = try? JSONEncoder().encode(text),
              let textJSON = String(data: textData, encoding: .utf8),
              let idData = try? JSONEncoder().encode(convId ?? ""),
              let idJSON = String(data: idData, encoding: .utf8) else { return }
        pendingReplyText = text
        let js = """
        (function(reply, convId){
          function post(o){ try { window.webkit.messageHandlers['\(WebBridge.handlerName)'].postMessage(o); } catch(e){} }
          function fail(r){ post({ type: 'replyResult', ok: false, reason: r }); }
          if (!convId) { fail('no-conversation-id'); return; }
          var link = document.querySelector('a[data-e2e-conversation="' + convId + '"]');
          if (!link) { fail('conversation-not-found'); return; }
          link.click();
          var t0 = Date.now();
          (function waitBox(){
            var box = document.querySelector('textarea[data-e2e-message-input-box], mws-message-compose textarea, textarea, [contenteditable="true"]');
            if (!box) {
              if (Date.now() - t0 > 6000) { fail('composer-not-found'); return; }
              setTimeout(waitBox, 100); return;
            }
            box.focus();
            if ('value' in box) {
              var setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set;
              setter.call(box, reply);
              box.dispatchEvent(new Event('input', { bubbles: true }));
            } else {
              box.textContent = reply;
              box.dispatchEvent(new Event('input', { bubbles: true }));
            }
            var t1 = Date.now();
            (function waitSend(){
              var send = document.querySelector('[data-e2e-send-button], button[aria-label*="Send" i]');
              if (!send || send.disabled) {
                if (Date.now() - t1 > 4000) { fail('send-button-unavailable'); return; }
                setTimeout(waitSend, 100); return;
              }
              send.click();
              post({ type: 'replyResult', ok: true });
            })();
          })();
        })(\(textJSON), \(idJSON));
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // A reply that silently vanishes is worse than one that fails loudly — the
    // user believes it sent. State the cause and hand the text back.
    private func handleReplyResult(ok: Bool, reason: String?) {
        let text = pendingReplyText
        pendingReplyText = nil
        guard !ok else { return }
        let detail = reason ?? "unknown"
        NSLog("[Textem] inline reply failed: %@", detail)
        var preview = ""
        if let text, !text.isEmpty { preview = " — “\(text.prefix(60))”" }
        NotificationManager.shared.notifyInfo(
            "Reply not sent (\(detail))\(preview). Open Textem to send it.")
    }

    // Inject/refresh the privacy CSS (blur messages, hide avatars) based on
    // current prefs. Display-only; does not change what is sent.
    @objc func applyPrivacyCSS() {
        var css = ""
        if Preferences.hideAvatars {
            css += "mws-avatar{visibility:hidden !important;}"
        }
        if Preferences.blurMessages {
            css += "mws-conversation-snippet,mws-text-message-part{filter:blur(6px);transition:filter .12s;}"
            css += "mws-conversation-snippet:hover,mws-text-message-part:hover{filter:none;}"
        }
        guard let data = try? JSONEncoder().encode(css),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = """
        (function(css){
          var s = document.getElementById('textem-privacy');
          if (!s) { s = document.createElement('style'); s.id = 'textem-privacy'; document.documentElement.appendChild(s); }
          s.textContent = css;
        })(\(json));
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
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

    // Copy the most recent verification code to the clipboard (Texty Pro
    // parity). Scans conversation snippets + visible message text for a 4–8
    // digit number and copies the newest match. macOS's built-in SMS-code
    // autofill only covers Apple Messages, so this fills the gap here.
    @objc func copyLatestCode(_ sender: Any?) {
        let js = """
        (function(){
          var nodes = document.querySelectorAll('mws-text-message-part, mws-conversation-snippet');
          var re = /\\b(\\d{4,8})\\b/;
          for (var i = nodes.length - 1; i >= 0; i--) {
            var t = nodes[i].textContent || '';
            var m = t.match(re);
            if (m) return m[1];
          }
          return '';
        })();
        """
        webView.evaluateJavaScript(js) { result, _ in
            let code = (result as? String) ?? ""
            Task { @MainActor in
                guard !code.isEmpty else { NSSound.beep(); return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                NotificationManager.shared.notifyInfo("Copied code \(code)")
            }
        }
    }

    // Start a new conversation by clicking Google's compose FAB (mw-fab-link,
    // confirmed present in the DOM). Texty Pro parity via ⌘N / Dock menu.
    @objc func compose(_ sender: Any?) {
        let js = "(function(){var f=document.querySelector('mw-fab-link a, mw-fab-link button, mw-fab-link');if(f){f.click();return true;}return false;})();"
        webView.evaluateJavaScript(js, completionHandler: nil)
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

    // Writes what the web view actually contains — URL, load state, and whether
    // the Messages DOM or a sign-in form is present — to /tmp/textem-selfcheck.log.
    private func scheduleSelfCheck() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self else { return }
            let native = "url=\(self.webView.url?.absoluteString ?? "nil")"
                + " title=\(self.webView.title ?? "nil")"
                + " loading=\(self.webView.isLoading)"
                + " progress=\(String(format: "%.2f", self.webView.estimatedProgress))"
            let js = """
            JSON.stringify({
              href: location.href,
              ready: document.readyState,
              bodyLen: document.body ? (document.body.innerText || '').length : -1,
              convItems: document.querySelectorAll('mws-conversation-list-item').length,
              signInForm: !!document.querySelector('input[type=email], #identifierId')
            })
            """
            // Structure of a conversation row + composer, so reply-targeting can be
            // built on the real DOM. SHAPE ONLY: ids masked, no text scraped.
            let shapeJS = """
            (function(){
              function attrs(e){ var o=[]; for (var i=0;i<e.attributes.length;i++) o.push(e.attributes[i].name); return o; }
              var el = document.querySelector('mws-conversation-list-item');
              if (!el) return JSON.stringify({found:false});
              var a = el.querySelector('a[href]');
              var href = a ? a.getAttribute('href') : null;
              var dataAttrs = [];
              var all = el.querySelectorAll('*');
              for (var k=0;k<all.length && dataAttrs.length<15;k++){
                for (var m=0;m<all[k].attributes.length;m++){
                  var n = all[k].attributes[m].name;
                  if (n.indexOf('data-')===0 && dataAttrs.indexOf(n)===-1) dataAttrs.push(n);
                }
              }
              var box = document.querySelector('textarea[data-e2e-message-input-box], mws-message-compose textarea, textarea, [contenteditable="true"]');
              var send = document.querySelector('[data-e2e-send-button], button[aria-label*="Send" i]');
              return JSON.stringify({
                found:true,
                itemAttrs: attrs(el),
                linkAttrs: a ? attrs(a) : null,
                hrefShape: href ? href.replace(/[A-Za-z0-9_-]{8,}/g,'<id>') : null,
                dataAttrs: dataAttrs,
                composer: box ? box.tagName + ':' + attrs(box).join(',') : null,
                sendBtn: send ? send.tagName + ':' + attrs(send).join(',') : null
              });
            })()
            """
            let page = (try? await self.webView.evaluateJavaScript(js)) as? String ?? "js-unavailable"
            let shape = (try? await self.webView.evaluateJavaScript(shapeJS)) as? String ?? "js-unavailable"
            let text = "[selfcheck] \(native)\npage=\(page)\nshape=\(shape)\n"
            try? text.write(toFile: "/tmp/textem-selfcheck.log", atomically: true, encoding: .utf8)
        }
    }

    // Immediate retry (Retry button); clears any pending backoff.
    private func retryLoadNow() {
        loadRetryTask?.cancel()
        loadRetryCount = 0
        errorView.isHidden = true
        webView.load(URLRequest(url: Self.messagesURL))
    }

    // A failed navigation has no UI of its own — see the note on `errorView`.
    // Transient faults get retried with exponential backoff; once those are
    // spent we state the cause rather than leaving a blank window.
    private func handleLoadFailure(_ error: Error) {
        let ns = error as NSError
        // Cancellations are normal (redirects, our own decidePolicy .cancel),
        // not failures — retrying them would fight the page.
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain", ns.code == 102 { return }  // frame load interrupted

        NSLog("[Textem] load failed (attempt %d/%d): %@ %d %@",
              loadRetryCount + 1, Self.maxLoadRetries, ns.domain, ns.code, ns.localizedDescription)

        guard loadRetryCount < Self.maxLoadRetries else {
            errorView.present(message: ns.localizedDescription
                + "\n\nTextem couldn’t load Google Messages. Check your connection, then Retry.")
            return
        }
        loadRetryCount += 1
        let delay = pow(2.0, Double(loadRetryCount - 1))  // 1, 2, 4, 8, 16s
        loadRetryTask?.cancel()
        loadRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.webView.load(URLRequest(url: Self.messagesURL))
        }
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
        // A good load clears the failure state.
        loadRetryCount = 0
        loadRetryTask?.cancel()
        errorView.isHidden = true
        applyZoom()
        applyPrivacyCSS()
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        handleLoadFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadFailure(error)
    }
}

extension WebViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                              didReceive message: WKScriptMessage) {
        guard message.name == WebBridge.handlerName,
              let body = message.body as? [String: Any] else { return }
        switch body["type"] as? String {
        case "unread":
            let count = (body["count"] as? Int) ?? (body["count"] as? NSNumber)?.intValue ?? 0
            handleUnread(count,
                         sender: body["sender"] as? String,
                         snippet: body["snippet"] as? String,
                         convId: body["convId"] as? String)
        case "replyResult":
            handleReplyResult(ok: (body["ok"] as? Bool) ?? false, reason: body["reason"] as? String)
        default:
            return
        }
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
