import AppKit
import WebKit

final class WebViewController: NSViewController {
    // The web client. Google gates this on the User-Agent; a mobile or
    // unrecognized UA gets a degraded page or a refusal.
    private static let messagesURL = URL(string: "https://messages.google.com/web/")!

    // Entry point for every load path (initial, retry, reload-from-origin).
    // TEXTEM_FORCE_LOAD_FAIL=1 swaps in an unresolvable host (.invalid is
    // reserved by RFC 2606, so DNS is guaranteed to fail) to exercise the
    // failure path on demand — a transient network fault is precisely the thing
    // you cannot summon when you want to verify the handling for it.
    private static var entryURL: URL {
        if ProcessInfo.processInfo.environment["TEXTEM_FORCE_LOAD_FAIL"] == "1" {
            return URL(string: "https://textem-force-load-fail.invalid/")!
        }
        return messagesURL
    }

    private static func isAllowedNavigationURL(_ url: URL) -> Bool {
        if WebNavigationPolicy.isAllowedTopLevelURL(url) { return true }
        return ProcessInfo.processInfo.environment["TEXTEM_FORCE_LOAD_FAIL"] == "1"
            && url.host == "textem-force-load-fail.invalid"
    }

    // Present as desktop Safari. This is the single most load-bearing line
    // in the whole spike — without it Google may not serve the full client,
    // and it's our first lever if the new account sign-in gets blocked as
    // an "insecure browser".
    static var desktopUserAgent: String {
        // Safari intentionally freezes the macOS token at 10_15_7 for web
        // compatibility. Read the installed Safari version so Textem does not
        // impersonate one increasingly stale browser forever.
        let safariVersion = Bundle(path: "/Applications/Safari.app")?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let version = safariVersion?.split(separator: ".").prefix(2).joined(separator: ".")
            ?? "17.4"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Safari/605.1.15"
    }

    private var webView: WKWebView!
    // Retain live popup windows (e.g. the Google verification popup) so they
    // aren't deallocated mid-flow.
    private var popups: [PopupWindowController] = []
    // Notified whenever the unread count changes (drives the menu-bar item).
    var onUnreadCountChanged: ((Int) -> Void)?
    private let accountID: UUID
    // The account's isolated session store.
    private let dataStore: WKWebsiteDataStore
    private var activityTracker = ConversationActivityTracker()
    private var bridgeReady = false
    // Find-in-page overlay (⌘F).
    private var findBar: FindBar!
    // Load-failure recovery. WKWebView paints a FAILED navigation as a blank
    // white page and reports nothing on its own, so without this a transient
    // fault (offline at login, sleep/wake, DNS blip) strands the user on a white
    // window forever. Retry with backoff, then surface a real error.
    private var errorView: LoadErrorView!
    private struct PendingReply {
        let id: UUID
        let text: String
        let conversationID: String
    }
    private var replyQueue: [PendingReply] = []
    private var activeReply: PendingReply?
    private var replyTimeoutTask: Task<Void, Never>?
    private var pendingOpenConversationID: String?
    private var pendingOpenAttempts = 0
    private var loadRetryCount = 0
    private var loadRetryTask: Task<Void, Never>?
    private static let maxLoadRetries = 5

    init(accountID: UUID, dataStore: WKWebsiteDataStore) {
        self.accountID = accountID
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

        // Opt-in, metadata-only diagnostic for messages that Google marks as
        // phone-only. It must be present at document start to observe receive
        // traffic; normal launches never install it.
        if ProcessInfo.processInfo.environment["TEXTEM_PAYLOAD_PROBE"] == "1" {
            PayloadProbe.prepareLog()
            controller.add(WeakScriptMessageHandler(self), name: PayloadProbe.handlerName)
            controller.addUserScript(WKUserScript(
                source: PayloadProbe.userScript(targetHint:
                    ProcessInfo.processInfo.environment["TEXTEM_PAYLOAD_PROBE_TARGET"]),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }

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
        #if DEBUG
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        #endif

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

    private func handleSnapshot(_ count: Int, rows: [ConversationSnapshot]) {
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
        let events = activityTracker.update(rows)
        if !NSApp.isActive, !Preferences.notificationsMuted {
            for event in events {
                NotificationManager.shared.notifyNewMessage(
                    sender: event.sender,
                    snippet: event.snippet,
                    accountID: accountID,
                    conversationID: event.id
                )
            }
        }
        onUnreadCountChanged?(count)
        bridgeReady = true
        openPendingConversationIfReady()
        processNextReplyIfReady()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        webView.load(URLRequest(url: Self.entryURL))
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

    // Notification replies are queued and run one at a time. The page must
    // report a real Messages snapshot before automation starts, which also lets
    // a reply switch back to its originating account without racing page load.
    func quickReply(_ text: String, conversationID: String?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let conversationID, !conversationID.isEmpty else {
            NotificationManager.shared.notifyInfo("Reply not sent: missing message or conversation.")
            return
        }
        replyQueue.append(PendingReply(
            id: UUID(), text: text, conversationID: conversationID))
        processNextReplyIfReady()
    }

    func openConversation(_ conversationID: String?) {
        guard let conversationID, !conversationID.isEmpty else { return }
        pendingOpenConversationID = conversationID
        pendingOpenAttempts = 0
        openPendingConversationIfReady()
    }

    private func openPendingConversationIfReady() {
        guard bridgeReady, let conversationID = pendingOpenConversationID,
              let idJSON = Self.jsonString(conversationID) else { return }
        pendingOpenConversationID = nil
        let js = """
        (function(convId) {
          var links = document.querySelectorAll('a[data-e2e-conversation]');
          for (var i = 0; i < links.length; i++) {
            if (links[i].getAttribute('data-e2e-conversation') === convId) {
              links[i].click();
              return true;
            }
          }
          return false;
        })(\(idJSON));
        """
        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard error != nil || (result as? Bool) != true else { return }
            Task { @MainActor in
                guard let self else { return }
                self.pendingOpenAttempts += 1
                if self.pendingOpenAttempts >= 3 {
                    NotificationManager.shared.notifyInfo(
                        "The conversation from that notification is no longer in the list.")
                } else {
                    self.pendingOpenConversationID = conversationID
                }
            }
        }
    }

    private func processNextReplyIfReady() {
        guard bridgeReady, activeReply == nil, !replyQueue.isEmpty else { return }
        let reply = replyQueue.removeFirst()
        activeReply = reply
        guard let requestJSON = Self.jsonString(reply.id.uuidString),
              let textJSON = Self.jsonString(reply.text),
              let idJSON = Self.jsonString(reply.conversationID) else {
            finishReply(reply, ok: false, statusUnknown: false, reason: "encoding-failed")
            return
        }

        // Fail closed: after clicking the row, wait until location exactly
        // matches that row's href before querying a composer. The old code
        // queried immediately and could type into the previously open thread.
        let js = """
        (function(requestId, reply, convId) {
          function post(o) {
            o.type = 'replyResult'; o.requestId = requestId;
            try { window.webkit.messageHandlers['\(WebBridge.handlerName)'].postMessage(o); } catch(e) {}
          }
          function fail(reason) { post({ ok: false, unknown: false, reason: reason }); }
          function route(url) {
            var u = new URL(url, location.href);
            return u.origin + u.pathname + u.search + u.hash;
          }
          function valueOf(box) {
            return ('value' in box) ? box.value : (box.textContent || '');
          }

          var links = document.querySelectorAll('a[data-e2e-conversation]');
          var link = null;
          for (var i = 0; i < links.length; i++) {
            if (links[i].getAttribute('data-e2e-conversation') === convId) { link = links[i]; break; }
          }
          if (!link || !link.href) { fail('conversation-not-found'); return; }
          var targetRoute = route(link.href);
          if (route(location.href) !== targetRoute) link.click();

          var started = Date.now();
          (function waitForTarget() {
            if (route(location.href) !== targetRoute) {
              if (Date.now() - started > 10000) { fail('conversation-not-selected'); return; }
              setTimeout(waitForTarget, 100); return;
            }

            var box = document.querySelector(
              'textarea[data-e2e-message-input-box], mws-message-compose textarea, mws-message-compose [contenteditable="true"]');
            if (!box) {
              if (Date.now() - started > 10000) { fail('composer-not-found'); return; }
              setTimeout(waitForTarget, 100); return;
            }

            box.focus();
            if ('value' in box) {
              var proto = box instanceof HTMLTextAreaElement
                ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
              var descriptor = Object.getOwnPropertyDescriptor(proto, 'value');
              if (!descriptor || !descriptor.set) { fail('composer-unsupported'); return; }
              descriptor.set.call(box, reply);
            } else {
              box.textContent = reply;
            }
            box.dispatchEvent(new InputEvent('input', {
              bubbles: true, inputType: 'insertText', data: reply
            }));

            var sendStarted = Date.now();
            (function waitForSend() {
              if (route(location.href) !== targetRoute) { fail('conversation-changed'); return; }
              if (valueOf(box) !== reply) {
                if (Date.now() - sendStarted > 4000) { fail('composer-rejected-text'); return; }
                setTimeout(waitForSend, 100); return;
              }
              var compose = box.closest('mws-message-compose');
              var send = compose ? compose.querySelector('[data-e2e-send-button], button[aria-label="Send"]') : null;
              if (!send) send = document.querySelector('[data-e2e-send-button]');
              if (!send || send.disabled) {
                if (Date.now() - sendStarted > 4000) { fail('send-button-unavailable'); return; }
                setTimeout(waitForSend, 100); return;
              }
              send.click();

              var confirmStarted = Date.now();
              (function confirmSubmission() {
                if (valueOf(box) === '') { post({ ok: true }); return; }
                if (Date.now() - confirmStarted > 5000) {
                  post({ ok: false, unknown: true, reason: 'submission-unconfirmed' });
                  return;
                }
                setTimeout(confirmSubmission, 100);
              })();
            })();
          })();
        })(\(requestJSON), \(textJSON), \(idJSON));
        """

        webView.evaluateJavaScript(js) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.finishReply(reply, ok: false, statusUnknown: false,
                                  reason: "javascript-error: \(error.localizedDescription)")
            }
        }
        replyTimeoutTask?.cancel()
        replyTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 22_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.finishReply(reply, ok: false, statusUnknown: true, reason: "timed-out")
        }
    }

    private func finishReply(_ reply: PendingReply, ok: Bool,
                             statusUnknown: Bool, reason: String?) {
        guard activeReply?.id == reply.id else { return }
        activeReply = nil
        replyTimeoutTask?.cancel()
        replyTimeoutTask = nil
        if !ok {
            let detail = reason ?? "unknown"
            NSLog("[Textem] inline reply failed: %@", detail)
            if statusUnknown {
                NotificationManager.shared.notifyInfo(
                    "Reply status unknown (\(detail)). Check the thread before resending.")
            } else {
                let preview = Preferences.hideNotificationPreview
                    ? "" : " — “\(reply.text.prefix(60))”"
                NotificationManager.shared.notifyInfo(
                    "Reply not sent (\(detail))\(preview). Open Textem to send it.")
            }
        }
        processNextReplyIfReady()
    }

    private static func jsonString(_ value: String) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
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
        bridgeReady = false
        replyTimeoutTask?.cancel()
        replyTimeoutTask = nil
        if activeReply != nil || !replyQueue.isEmpty {
            NotificationManager.shared.notifyInfo(
                "Reply not sent because the active account changed.")
        }
        activeReply = nil
        replyQueue.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.removeScriptMessageHandler(forName: WebBridge.handlerName)
        controller.removeScriptMessageHandler(forName: PayloadProbe.handlerName)
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
                NotificationManager.shared.notifyInfo(
                    Preferences.hideNotificationPreview
                        ? "Copied verification code" : "Copied code \(code)")
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
        webView.load(URLRequest(url: Self.entryURL))
    }

    // Writes what the web view actually contains — URL, load state, and whether
    // the Messages DOM or a sign-in form is present — to /tmp/textem-selfcheck.log.
    private func scheduleSelfCheck() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self else { return }
            let native = "errorShown=\(!(self.errorView?.isHidden ?? true))"
                + " url=\(self.webView.url?.absoluteString ?? "nil")"
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
            let path = ProcessInfo.processInfo.environment["TEXTEM_SELFCHECK_PATH"]
                ?? "/tmp/textem-selfcheck.log"
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // Immediate retry (Retry button); clears any pending backoff.
    private func retryLoadNow() {
        loadRetryTask?.cancel()
        loadRetryCount = 0
        errorView.isHidden = true
        webView.load(URLRequest(url: Self.entryURL))
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
                + "\n\nTextem couldn’t load Google Messages. Check your connection, then Retry.",
                isRetrying: false)
            return
        }
        loadRetryCount += 1
        let delay = pow(2.0, Double(loadRetryCount - 1))  // 1, 2, 4, 8, 16s
        errorView.present(
            message: "\(ns.localizedDescription)\n\nRetrying in \(Int(delay))s "
                + "(attempt \(loadRetryCount) of \(Self.maxLoadRetries))…",
            isRetrying: true)
        loadRetryTask?.cancel()
        loadRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.webView.load(URLRequest(url: Self.entryURL))
        }
    }

}

extension WebViewController: WKNavigationDelegate {
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
            : Self.isAllowedNavigationURL(url)
        guard isAllowed else {
            // Only explicit user gestures may launch another application. A
            // script/redirect to an untrusted origin is simply blocked.
            if navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        bridgeReady = false
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

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        bridgeReady = false
        handleLoadFailure(NSError(
            domain: "Textem.WebKit",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The Google Messages web process stopped unexpectedly."]
        ))
    }
}

extension WebViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                              didReceive message: WKScriptMessage) {
        guard message.webView === webView,
              message.frameInfo.isMainFrame,
              WebNavigationPolicy.isAllowedBridgeOrigin(
                scheme: message.frameInfo.securityOrigin.protocol,
                host: message.frameInfo.securityOrigin.host) else { return }

        if message.name == PayloadProbe.handlerName {
            if let event = message.body as? [String: Any] { PayloadProbe.log(event) }
            return
        }

        guard message.name == WebBridge.handlerName,
              let body = message.body as? [String: Any] else { return }
        switch body["type"] as? String {
        case "snapshot":
            let count = (body["count"] as? Int) ?? (body["count"] as? NSNumber)?.intValue ?? 0
            let rows = (body["rows"] as? [[String: Any]] ?? []).compactMap { row -> ConversationSnapshot? in
                guard let id = row["id"] as? String, !id.isEmpty,
                      let fingerprint = row["fingerprint"] as? String else { return nil }
                return ConversationSnapshot(
                    id: id,
                    sender: row["sender"] as? String ?? "",
                    snippet: row["snippet"] as? String ?? "",
                    fingerprint: fingerprint,
                    isUnread: (row["unread"] as? Bool) ?? false
                )
            }
            handleSnapshot(count, rows: rows)
        case "replyResult":
            guard let rawID = body["requestId"] as? String,
                  let id = UUID(uuidString: rawID),
                  let reply = activeReply, reply.id == id else { return }
            finishReply(
                reply,
                ok: (body["ok"] as? Bool) ?? false,
                statusUnknown: (body["unknown"] as? Bool) ?? false,
                reason: body["reason"] as? String
            )
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
        guard let url = navigationAction.request.url,
              WebNavigationPolicy.isAllowedTopLevelURL(url) else {
            if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
            return nil
        }
        let popup = PopupWindowController(configuration: configuration) { [weak self] controller in
            self?.popups.removeAll { $0 === controller }
        }
        popups.append(popup)
        popup.showWindow(nil)
        popup.window?.makeKeyAndOrderFront(nil)
        return popup.webView
    }
}
