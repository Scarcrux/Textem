import AppKit
import SwiftUI
import WebKit

final class WebViewController: NSViewController {
    // The web client. Google gates this on the User-Agent; a mobile or
    // unrecognized UA gets a degraded page or a refusal.
    private static let messagesURL = URL(string: "https://messages.google.com/web/")!
    // Google Messages keeps a fixed conversation-list rail at desktop widths
    // and a 64-point global toolbar above both columns. Native phone-only
    // content replaces only the selected conversation region, preserving those
    // two pieces of spatial context instead of floating over the page. The
    // toolbar inset is relative to the view's safe area because this window's
    // full-size content view extends behind the macOS title bar while WebKit's
    // visible page does not.
    private static let conversationListWidth: CGFloat = 340
    private static let globalToolbarHeight: CGFloat = 64
    private static let phoneFallbackSnapshotHTML = """
    <!doctype html><html><head><style>
    *{box-sizing:border-box}html,body{margin:0;width:100%;height:100%;overflow:hidden;
      background:#202124;color:#e8eaed;font:14px -apple-system,BlinkMacSystemFont,sans-serif}
    header{height:64px;display:flex;align-items:center;padding:0 24px;border-bottom:1px solid #3c4043;
      background:#202124;font-size:19px;font-weight:600}header span{margin-left:auto;width:32px;height:32px;
      border-radius:50%;display:grid;place-items:center;background:#0b57d0;font-size:14px}
    aside{position:absolute;left:0;top:64px;bottom:0;width:340px;background:#292a2d;
      border-right:1px solid #3c4043;padding:18px 12px}
    button{border:0;border-radius:16px;background:#a8c7fa;color:#062e6f;padding:13px 18px;
      font:600 14px -apple-system;margin:0 8px 18px}
    .row{height:72px;border-radius:12px;display:flex;align-items:center;gap:12px;padding:0 12px}
    .row.selected{background:#3c4043}.avatar{width:40px;height:40px;border-radius:50%;
      background:#7cacf8;display:grid;place-items:center;color:white;font-weight:700}.copy{min-width:0}
    .name{font-weight:600;margin-bottom:5px}.snippet{color:#bdc1c6;white-space:nowrap;overflow:hidden;
      text-overflow:ellipsis;width:220px}main{position:absolute;left:340px;right:0;top:64px;bottom:0;
      background:#202124;display:grid;place-items:center;color:#9aa0a6}
    </style></head><body><header>☰ &nbsp; Google Messages<span>T</span></header><aside>
    <button>Start chat</button>
    <div class="row"><div class="avatar">A</div><div class="copy"><div class="name">Example contact</div><div class="snippet">A regular conversation</div></div></div>
    <div class="row selected"><div class="avatar">D</div><div class="copy"><div class="name">Demo delivery</div><div class="snippet">View on your phone</div></div></div>
    <div class="row"><div class="avatar">B</div><div class="copy"><div class="name">Another contact</div><div class="snippet">See you tomorrow</div></div></div>
    </aside><main>Phone-only conversation</main></body></html>
    """

    // The separate native helper cannot currently coexist with Google's web
    // relay: activating either client invalidates the other's listener. Keep
    // automatic recovery off in normal launches so merely selecting a thread
    // can never generate another phone pairing prompt. This switch exists only
    // for isolated developer verification while that protocol limitation is
    // investigated.
    private static var experimentalAutomaticRecoveryEnabled: Bool {
        PhoneOnlyRecoveryPolicy.automaticRecoveryEnabled(
            environment: ProcessInfo.processInfo.environment)
    }

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
    private var lastDiagnosticAt: Date?
    private var lastDiagnosticUnread: Int?
    private var lastDiagnosticRows: Int?
    private var lastDiagnosticDOMRows: Int?
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
    private var nativeSendReplyID: UUID?
    private var replyTimeoutTask: Task<Void, Never>?
    private var pendingOpenConversationID: String?
    private var pendingOpenAttempts = 0
    private var loadRetryCount = 0
    private var loadRetryTask: Task<Void, Never>?
    private var didExportLibGMCookies = false
    private var linkPreviewHost: NSView?
    private var showingPhoneImages = false
    private var phoneImagesModel: PhoneImagesModel?
    private var browsingPhoneImageLibrary = false
    private var currentImageConversation: PhoneImageConversation?
    private var displayedImageConversationKey: String?
    private var displayedLinkPreviewDocument: LinkPreviewDocument?
    private var dismissedPhoneOnlyConversation: String?
    private struct RecoverySelection {
        let conversation: String
        let conversationID: String
        var key: String {
            let route = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            return route.isEmpty ? LinkPreviewStore.normalizedConversation(conversation) : route
        }
    }
    private var currentPhoneOnlySelection: RecoverySelection?
    private var activeRecoveryID: UUID?
    private var activeRecoveryProcess: Process?
    private var activeRecoveryFiles: (request: URL, status: URL)?
    private var recoveryStatusTask: Task<Void, Never>?
    private var lastRecoveryRequest: [String: Date] = [:]
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

    // Content-free notification diagnostics. A missing banner has three
    // causes that look identical from outside the app: the page never got the
    // message (changed=0), Textem did not see it as unread (changed>0,
    // events=0), or the bridge stopped reporting (no lines, no heartbeat).
    // Logs counts and flags only — never names, snippets, or conversation IDs.
    // Writes on change, plus a heartbeat every 5 minutes to prove the bridge
    // is alive while Textem is in the background.
    private func logSnapshotDiagnostics(rows: Int, unread: Int, changed: Int, events: Int,
                                        domRows: Int) {
        let now = Date()
        let heartbeatDue = lastDiagnosticAt.map { now.timeIntervalSince($0) >= 300 } ?? true
        guard heartbeatDue || changed > 0 || events > 0 || unread != lastDiagnosticUnread
                || rows != lastDiagnosticRows || domRows != lastDiagnosticDOMRows else { return }
        lastDiagnosticAt = now
        lastDiagnosticUnread = unread
        lastDiagnosticRows = rows
        lastDiagnosticDOMRows = domRows
        let line = "[Textem] snapshot rows=\(rows) unread=\(unread) changed=\(changed) "
            + "events=\(events) active=\(NSApp.isActive ? "yes" : "no") "
            + "muted=\(Preferences.notificationsMuted ? "yes" : "no")"
        NSLog("%@", line)
        NotificationDiagnostics.record("snapshot", values: [
            "rows": rows, "domRows": domRows, "unread": unread,
            "changed": changed, "events": events,
            "active": NSApp.isActive ? 1 : 0,
            "muted": Preferences.notificationsMuted ? 1 : 0
        ])
    }

    private func handleSnapshot(_ count: Int, rows: [ConversationSnapshot], domRows: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
        let events = activityTracker.update(rows)
        logSnapshotDiagnostics(rows: rows.count, unread: count,
                               changed: activityTracker.changedContentCount,
                               events: events.count, domRows: domRows)
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

    private func handlePhoneOnlyState(
        visible: Bool, conversation: String, conversationID: String, routeConfirmed: Bool
    ) {
        if ProcessInfo.processInfo.environment["TEXTEM_PHONE_FALLBACK_SNAPSHOT"] == "1" {
            return
        }
        let normalized = LinkPreviewStore.normalizedConversation(conversation)
        let imageConversation = PhoneImageConversation(accountID: accountID, route: conversationID, label: conversation)
        currentImageConversation = visible && routeConfirmed && imageConversation.key != nil ? imageConversation : nil
        phoneImagesModel?.setConversation(currentImageConversation)
        if browsingPhoneImageLibrary { return }
        guard visible else {
            // The native relay temporarily becomes Google's one active
            // computer. Keep the recovery pane and route while it works; the
            // bridge is explicitly reactivated after capture completes.
            if activeRecoveryID != nil { return }
            currentPhoneOnlySelection = nil
            dismissedPhoneOnlyConversation = nil
            hideLinkPreviewFallback()
            return
        }
        guard !normalized.isEmpty else {
            hideLinkPreviewFallback()
            return
        }
        let selection = RecoverySelection(
            conversation: conversation, conversationID: conversationID)
        currentPhoneOnlySelection = selection
        if let context = currentImageConversation, dismissedPhoneOnlyConversation != normalized,
           let images = try? PhoneImageStore.images(for: context), !images.isEmpty {
            showConversationImages(context); return
        }
        if dismissedPhoneOnlyConversation != normalized,
           let document = try? LinkPreviewStore.load(
                matching: conversation, webConversationID: conversationID) {
            showLinkPreviewFallback(document)
        } else if dismissedPhoneOnlyConversation != normalized {
            hideLinkPreviewFallback()
        }
        if Self.experimentalAutomaticRecoveryEnabled {
            requestPhoneOnlyRecovery(selection)
        }
    }

    private func requestPhoneOnlyRecovery(_ selection: RecoverySelection) {
        guard activeRecoveryID == nil else { return }
        if let last = lastRecoveryRequest[selection.key], Date().timeIntervalSince(last) < 60 {
            return
        }
        lastRecoveryRequest[selection.key] = Date()
        guard PhoneOnlyRecoveryFiles.helperIsPrivateExecutable() else {
            showPhoneOnlyRecovery(selection, status: PhoneOnlyCaptureStatus(
                schema: 1, state: "error", emoji: nil, errorCode: "helper-not-installed"))
            return
        }

        let runID = UUID()
        activeRecoveryID = runID
        if displayedLinkPreviewDocument == nil {
            showPhoneOnlyRecovery(selection, status: PhoneOnlyCaptureStatus(
                schema: 1, state: "starting", emoji: nil, errorCode: nil))
        }
        // A fresh browser cookie handoff repairs a still-paired native session
        // when Google rotates web credentials; it does not create another
        // paired device for each conversation.
        LibGMCookieExporter.export(from: dataStore) { [weak self] result in
            guard let self, self.activeRecoveryID == runID else { return }
            switch result {
            case .success:
                self.launchPhoneOnlyRecovery(selection, runID: runID)
            case .failure:
                self.finishPhoneOnlyRecovery(
                    selection, runID: runID, succeeded: false,
                    fallbackErrorCode: "cookie-handoff-failed")
            }
        }
    }

    private func launchPhoneOnlyRecovery(_ selection: RecoverySelection, runID: UUID) {
        do {
            let files = try PhoneOnlyRecoveryFiles.makeRequest(
                conversation: selection.conversation,
                webConversationID: selection.conversationID)
            let process = Process()
            process.executableURL = PhoneOnlyRecoveryFiles.helperURL
            process.arguments = [
                "-state-dir", PhoneOnlyRecoveryFiles.stateDirectory.path,
                "-request", files.request.path,
                "-status", files.status.path,
                "-messages", "100",
                "-listen", "2s",
                "-timeout", "3m",
                "-write-previews",
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] completed in
                Task { @MainActor in
                    self?.finishPhoneOnlyRecovery(
                        selection, runID: runID,
                        succeeded: completed.terminationReason == .exit
                            && completed.terminationStatus == 0,
                        fallbackErrorCode: "helper-exited")
                }
            }
            activeRecoveryFiles = files
            activeRecoveryProcess = process
            try process.run()
            pollPhoneOnlyRecoveryStatus(selection, runID: runID, statusURL: files.status)
        } catch {
            finishPhoneOnlyRecovery(
                selection, runID: runID, succeeded: false,
                fallbackErrorCode: "helper-launch-failed")
        }
    }

    private func pollPhoneOnlyRecoveryStatus(
        _ selection: RecoverySelection, runID: UUID, statusURL: URL
    ) {
        recoveryStatusTask?.cancel()
        recoveryStatusTask = Task { @MainActor [weak self] in
            var previous: PhoneOnlyCaptureStatus?
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, self.activeRecoveryID == runID else { return }
                guard let status = try? PhoneOnlyRecoveryFiles.readStatus(from: statusURL),
                      status != previous else { continue }
                previous = status
                if self.currentPhoneOnlySelection?.key == selection.key,
                   (self.displayedLinkPreviewDocument == nil
                    || status.state == "pairing" || status.state == "error") {
                    self.showPhoneOnlyRecovery(selection, status: status)
                }
            }
        }
    }

    private func finishPhoneOnlyRecovery(
        _ selection: RecoverySelection, runID: UUID, succeeded: Bool,
        fallbackErrorCode: String
    ) {
        guard activeRecoveryID == runID else { return }
        let finalStatus = activeRecoveryFiles.flatMap {
            try? PhoneOnlyRecoveryFiles.readStatus(from: $0.status)
        }
        recoveryStatusTask?.cancel()
        recoveryStatusTask = nil
        if let files = activeRecoveryFiles {
            PhoneOnlyRecoveryFiles.removeRunFiles(request: files.request, status: files.status)
        }
        activeRecoveryFiles = nil
        activeRecoveryProcess = nil
        activeRecoveryID = nil

        guard currentPhoneOnlySelection?.key == selection.key else {
            if Self.experimentalAutomaticRecoveryEnabled, let currentPhoneOnlySelection {
                requestPhoneOnlyRecovery(currentPhoneOnlySelection)
            }
            return
        }
        if succeeded,
           let document = try? LinkPreviewStore.load(
                matching: selection.conversation,
                webConversationID: selection.conversationID) {
            showLinkPreviewFallback(document)
        } else {
            showPhoneOnlyRecovery(selection, status: PhoneOnlyCaptureStatus(
                schema: 1, state: "error", emoji: nil,
                errorCode: finalStatus?.errorCode ?? fallbackErrorCode))
        }
    }

    private func showPhoneOnlyRecovery(
        _ selection: RecoverySelection, status: PhoneOnlyCaptureStatus
    ) {
        guard dismissedPhoneOnlyConversation
                != LinkPreviewStore.normalizedConversation(selection.conversation) else { return }
        let host = NSHostingView(rootView: PhoneOnlyRecoveryView(
            conversation: selection.conversation,
            state: status.state,
            emoji: status.emoji,
            errorCode: status.errorCode,
            onClose: { [weak self] in
                self?.dismissedPhoneOnlyConversation =
                    LinkPreviewStore.normalizedConversation(selection.conversation)
                self?.hideLinkPreviewFallback()
            }
        ))
        installLinkPreviewHost(host)
        displayedLinkPreviewDocument = nil
    }

    private func showLinkPreviewFallback(_ document: LinkPreviewDocument) {
        if linkPreviewHost != nil, displayedLinkPreviewDocument == document { return }
        let host = NSHostingView(rootView: LinkPreviewFallbackView(
            document: document,
            onClose: { [weak self] in
                guard let self else { return }
                self.dismissedPhoneOnlyConversation =
                    LinkPreviewStore.normalizedConversation(document.conversation)
                self.hideLinkPreviewFallback()
            }
        ))
        installLinkPreviewHost(host)
        displayedLinkPreviewDocument = document
    }

    func showLinkPreviewLibrary() throws {
        let documents = try LinkPreviewStore.loadAll()
        let host = NSHostingView(rootView: LinkPreviewLibraryView(
            documents: documents,
            onClose: { [weak self] in self?.hideLinkPreviewFallback() }
        ))
        installLinkPreviewHost(host)
        displayedLinkPreviewDocument = nil
    }

    func showPhoneImages() {
        let model = imageModel()
        model.setConversation(currentImageConversation, only: false); model.reload()
        let host = NSHostingView(rootView: PhoneImagesView(model: model, onClose: { [weak self] in
            self?.dismissPhoneImages()
        }))
        installLinkPreviewHost(host); showingPhoneImages = true; browsingPhoneImageLibrary = true
        // Owner-invoked local verification only: normal launches never transfer automatically.
        if ProcessInfo.processInfo.environment["TEXTEM_PHONE_IMAGE_CHECK"] == "1" {
            if let endpoint = ProcessInfo.processInfo.environment["TEXTEM_PHONE_IMAGE_ENDPOINT"] { model.endpoint = endpoint }
            Task { @MainActor [weak host] in
                await model.importFromPhone()
                try? await Task.sleep(for: .seconds(1))
                guard let host, let path = ProcessInfo.processInfo.environment["TEXTEM_PHONE_IMAGE_SNAPSHOT"],
                      let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    FileManager.default.createFile(atPath: path, contents: png, attributes: [.posixPermissions: 0o600])
                }
            }
        }
    }

    private func imageModel() -> PhoneImagesModel {
        if let phoneImagesModel { return phoneImagesModel }
        let model = PhoneImagesModel()
        model.validateConversation = { [weak self] context in
            guard let self, context.accountID == self.accountID,
                  self.webView.url?.scheme == "https", self.webView.url?.host == "messages.google.com",
                  self.currentImageConversation?.key == context.key else { return false }
            let route = try? await self.webView.evaluateJavaScript(WebBridge.phoneImageRouteScript) as? String
            return route == context.route && self.currentImageConversation?.key == context.key
                && self.webView.url?.scheme == "https" && self.webView.url?.host == "messages.google.com"
        }
        phoneImagesModel = model; return model
    }

    private func dismissPhoneImages() {
        if let context = currentImageConversation {
            dismissedPhoneOnlyConversation = LinkPreviewStore.normalizedConversation(context.label)
        }
        hideLinkPreviewFallback()
    }

    private func showConversationImages(_ context: PhoneImageConversation) {
        let model = imageModel(); model.setConversation(context, only: true); model.reload()
        guard !showingPhoneImages || displayedImageConversationKey != context.key else { return }
        model.status = "Saved images explicitly linked to this conversation. No background phone scan."
        let host = NSHostingView(rootView: PhoneImagesView(model: model,
            onClose: { [weak self] in self?.dismissPhoneImages() },
            onOpenLibrary: { [weak self] in self?.showPhoneImages() }))
        installLinkPreviewHost(host); showingPhoneImages = true; displayedImageConversationKey = context.key
    }

    private func installLinkPreviewHost(_ host: NSView) {
        hideLinkPreviewFallback()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        view.addSubview(host, positioned: .above, relativeTo: webView)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: Self.conversationListWidth),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: Self.globalToolbarHeight),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        linkPreviewHost = host
    }

    private func hideLinkPreviewFallback() {
        showingPhoneImages = false
        browsingPhoneImageLibrary = false; displayedImageConversationKey = nil
        linkPreviewHost?.removeFromSuperview()
        linkPreviewHost = nil
        displayedLinkPreviewDocument = nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let phoneFallbackSnapshot =
            ProcessInfo.processInfo.environment["TEXTEM_PHONE_FALLBACK_SNAPSHOT"] == "1"
        let phoneRecoverySnapshot =
            ProcessInfo.processInfo.environment["TEXTEM_PHONE_RECOVERY_SNAPSHOT"] == "1"
        if phoneFallbackSnapshot || phoneRecoverySnapshot {
            webView.loadHTMLString(Self.phoneFallbackSnapshotHTML, baseURL: nil)
        } else {
            webView.load(URLRequest(url: Self.entryURL))
        }
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
        if phoneRecoverySnapshot {
            let selection = RecoverySelection(
                conversation: "Example delivery service", conversationID: "fixture-route")
            currentPhoneOnlySelection = selection
            showPhoneOnlyRecovery(selection, status: PhoneOnlyCaptureStatus(
                schema: 1, state: "pairing", emoji: "🦆", errorCode: nil))
            schedulePhoneFallbackSnapshot()
        } else if phoneFallbackSnapshot {
            do {
                try showLinkPreviewLibrary()
                schedulePhoneFallbackSnapshot()
            } catch {
                let diagnostic = "fallbackLoad=false file=\(LinkPreviewStore.defaultURL.lastPathComponent) "
                    + "error=\(error.localizedDescription)\n"
                try? diagnostic.write(
                    toFile: "/tmp/textem-phone-fallback-snapshot.txt",
                    atomically: true,
                    encoding: .utf8)
            }
        }
    }

    private func schedulePhoneFallbackSnapshot() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self,
                  let host = self.linkPreviewHost else {
                try? "fallbackHost=false\n".write(
                    toFile: "/tmp/textem-phone-fallback-snapshot.txt",
                    atomically: true,
                    encoding: .utf8)
                return
            }
            let view = self.view
            view.layoutSubtreeIfNeeded()
            host.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            host.displayIfNeeded()
            let diagnostic = "fallbackHost=true frame=\(NSStringFromRect(host.frame)) "
                + "subviews=\(host.subviews.count)\n"
            try? diagnostic.write(
                toFile: "/tmp/textem-phone-fallback-snapshot.txt",
                atomically: true,
                encoding: .utf8)
            guard
                  let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                return
            }
            view.cacheDisplay(in: view.bounds, to: representation)
            guard let data = representation.representation(using: .png, properties: [:]) else {
                return
            }
            let url = URL(fileURLWithPath: "/tmp/textem-phone-fallback-snapshot.png")
            do {
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                NSLog("[Textem] phone-fallback snapshot failed: %@", error.localizedDescription)
            }
        }
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
          \(ConversationDOM.helpers)
          var links = document.querySelectorAll('mws-conversation-list-item a[href]');
          for (var i = 0; i < links.length; i++) {
            if (textemConversationID(links[i]) === convId) {
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
        nativeSendReplyID = nil
        // The script is built by ReplyAutomation so the exact text injected here
        // is the one exercised against a fixture page in the WebKit tests.
        guard let js = ReplyAutomation.script(
            requestID: reply.id.uuidString, text: reply.text,
            conversationID: reply.conversationID) else {
            finishReply(reply, ok: false, statusUnknown: false, reason: "encoding-failed")
            return
        }

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

    private func sendReplyUsingNativeInput(_ reply: PendingReply) {
        guard activeReply?.id == reply.id, nativeSendReplyID != reply.id,
              let idJSON = Self.jsonString(reply.id.uuidString) else { return }
        nativeSendReplyID = reply.id
        let script = """
        (function() {
          return typeof window.__textemReplySendTarget === 'function'
            ? window.__textemReplySendTarget(\(idJSON)) : null;
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.activeReply?.id == reply.id else { return }
                guard error == nil, let target = result as? [String: Any],
                      let route = target["route"] as? String, let url = URL(string: route),
                      url.scheme == "https", url.host == "messages.google.com",
                      let expectedID = url.pathComponents.last,
                      expectedID.removingPercentEncoding == reply.conversationID,
                      self.webView.url?.absoluteString == route else {
                    self.finishReply(reply, ok: false, statusUnknown: false,
                                     reason: "native-target-changed")
                    return
                }
                let sent = NativeWebClick.send(in: self.webView, target: target)
                NotificationDiagnostics.record(sent ? "reply_native_dispatched" : "reply_native_unavailable")
                if !sent {
                    self.finishReply(reply, ok: false, statusUnknown: false,
                                     reason: "native-input-unavailable")
                }
            }
        }
    }

    private func finishReply(_ reply: PendingReply, ok: Bool,
                             statusUnknown: Bool, reason: String?) {
        guard activeReply?.id == reply.id else { return }
        activeReply = nil
        replyTimeoutTask?.cancel()
        replyTimeoutTask = nil
        let reasonCodes = [
            "conversation-not-found": 1, "conversation-not-selected": 2,
            "composer-not-found": 3, "composer-unsupported": 4,
            "composer-rejected-text": 5, "conversation-changed": 6,
            "send-button-unavailable": 7, "submission-unconfirmed": 8,
            "timed-out": 9, "encoding-failed": 10, "composer-ambiguous": 11,
            "composer-changed": 12, "send-button-ambiguous": 13,
            "native-target-changed": 14, "native-input-unavailable": 15
        ]
        NotificationDiagnostics.record(
            ok ? "reply_confirmed" : (statusUnknown ? "reply_unknown" : "reply_not_sent"),
            values: ["reason": reasonCodes[reason ?? ""] ?? 0])
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
        recoveryStatusTask?.cancel()
        recoveryStatusTask = nil
        activeRecoveryProcess?.terminate()
        if let files = activeRecoveryFiles {
            PhoneOnlyRecoveryFiles.removeRunFiles(request: files.request, status: files.status)
        }
        activeRecoveryProcess = nil
        activeRecoveryFiles = nil
        activeRecoveryID = nil
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
                + " fallbackHost=\(self.linkPreviewHost != nil)"
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
              function normalized(value){ return (value || '').replace(/\\s+/g, ' ').trim().toLocaleLowerCase(); }
              var buttons = document.querySelectorAll('button, [role="button"]');
              var buttonStates = {useHere:false, tryAgain:false, reconnect:false, reload:false};
              for (var buttonIndex=0; buttonIndex<buttons.length; buttonIndex++) {
                var buttonText = normalized(buttons[buttonIndex].textContent);
                if (buttonText === 'use here') buttonStates.useHere = true;
                if (buttonText === 'try again') buttonStates.tryAgain = true;
                if (buttonText === 'reconnect') buttonStates.reconnect = true;
                if (buttonText === 'reload') buttonStates.reload = true;
              }
              var el = document.querySelector('mws-conversation-list-item');
              if (!el) return JSON.stringify({
                found:false, buttonCount:buttons.length, buttonStates:buttonStates
              });
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
              var composerAncestors = [];
              var ancestor = box;
              for (var depth=0; ancestor && depth<6; depth++, ancestor=ancestor.parentElement) {
                composerAncestors.push({tag:ancestor.tagName, attrs:attrs(ancestor)});
              }
              var composerButtons = [];
              var scope = box ? (box.closest('mws-message-compose') || box.parentElement.parentElement.parentElement) : null;
              var composerInputs = Array.from(document.querySelectorAll(
                'textarea[data-e2e-message-input-box], mws-message-compose textarea, mws-message-compose [contenteditable="true"]'))
                .map(function(input) {
                  return {tag:input.tagName, hidden:input.hidden, rects:input.getClientRects().length,
                    disabled:!!input.disabled, composeRoot:!!input.closest('mws-message-compose'),
                    textChars:('value' in input ? input.value : (input.textContent || '')).length,
                    meaningfulChars:('value' in input ? input.value : (input.textContent || ''))
                      .replace(/[\\s\\u200b\\ufeff]/g, '').length};
                });
              if (scope) {
                scope.querySelectorAll('button, [role="button"], input[type="submit"]').forEach(function(button) {
                  composerButtons.push({
                    tag:button.tagName, attrs:attrs(button),
                    classes:Array.from(button.classList),
                    sendLabel:/^send\\b/i.test(button.getAttribute('aria-label') || ''),
                    disabled:!!button.disabled,
                    rects:button.getClientRects().length, hidden:button.hidden,
                    sendMarker:button.hasAttribute('data-e2e-send-button')
                  });
                });
              }
              var selected = document.querySelectorAll(
                'mws-conversation-list-item a[aria-selected="true"], ' +
                'mws-conversation-list-item [aria-selected="true"][href]');
              var selectedRow = selected.length ? selected[0].closest('mws-conversation-list-item') : null;
              var selectedName = selectedRow ? selectedRow.querySelector('[data-e2e-conversation-name], h3, .name') : null;
              var visibleText = (document.body && document.body.innerText) || '';
              var markerPrefix = 'Use the Google Messages app on your phone to chat with ';
              var markerConversationChars = 0;
              var visibleLines = visibleText.split(/\\r?\\n/);
              for (var lineIndex=0; lineIndex<visibleLines.length; lineIndex++) {
                var visibleLine = visibleLines[lineIndex].replace(/\\s+/g, ' ').trim();
                if (visibleLine.toLocaleLowerCase().indexOf(markerPrefix.toLocaleLowerCase()) === 0) {
                  markerConversationChars = visibleLine.slice(markerPrefix.length).trim().length;
                  break;
                }
              }
              return JSON.stringify({
                found:true,
                itemAttrs: attrs(el),
                linkAttrs: a ? attrs(a) : null,
                hrefShape: href ? href.replace(/[A-Za-z0-9_-]{8,}/g,'<id>') : null,
                dataAttrs: dataAttrs,
                conversationMarkerChars: a ? (a.getAttribute('data-e2e-conversation') || '').length : 0,
                routeMatchesConversation: a ? /^\\/web\\/conversations\\/[^/]+\\/?$/.test(new URL(a.href).pathname) : false,
                composer: box ? box.tagName + ':' + attrs(box).join(',') : null,
                sendBtn: send ? send.tagName + ':' + attrs(send).join(',') : null,
                composerAncestors:composerAncestors, composerButtons:composerButtons,
                composerInputs:composerInputs,
                selectedLinks: selected.length,
                selectedNameChars: selectedName ? (selectedName.textContent || '').trim().length : 0,
                markerConversationChars: markerConversationChars,
                phoneOnlyMarker: /use\\s+the\\s+google\\s+messages\\s+app\\s+on\\s+your\\s+phone\\s+to\\s+chat\\s+with/i.test(visibleText)
              });
            })()
            """
            let page = (try? await self.webView.evaluateJavaScript(js)) as? String ?? "js-unavailable"
            let shape = (try? await self.webView.evaluateJavaScript(shapeJS)) as? String ?? "js-unavailable"
            let text = "[selfcheck] \(native)\npage=\(page)\nshape=\(shape)\n"
            let path = ProcessInfo.processInfo.environment["TEXTEM_SELFCHECK_PATH"]
                ?? "/tmp/textem-selfcheck.log"
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
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
        exportLibGMCookiesIfRequested()
    }

    private func exportLibGMCookiesIfRequested() {
        guard LibGMCookieExporter.isEnabled, !didExportLibGMCookies else { return }
        didExportLibGMCookies = true
        LibGMCookieExporter.export(from: dataStore) { [weak self] result in
            switch result {
            case .success(let count):
                NSLog("[Textem] libgm probe cookie handoff ready (%d cookies)", count)
            case .failure(let error):
                self?.didExportLibGMCookies = false
                NSLog("[Textem] libgm probe cookie handoff failed: %@", error.localizedDescription)
            }
        }
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
            handleSnapshot(count, rows: rows, domRows: (body["domRows"] as? Int) ?? rows.count)
        case "phoneOnlyState":
            handlePhoneOnlyState(
                visible: (body["visible"] as? Bool) ?? false,
                conversation: body["conversation"] as? String ?? "",
                conversationID: body["conversationID"] as? String ?? "",
                routeConfirmed: (body["routeConfirmed"] as? Bool) ?? false
            )
        case "replyResult":
            guard let rawID = body["requestId"] as? String,
                  let id = UUID(uuidString: rawID),
                  let reply = activeReply, reply.id == id else { return }
            if let raw = body["diagnostics"] as? [String: Any] {
                let allowed = ["routeMatches", "originalConnected", "originalTextChars",
                    "originalMeaningfulChars", "freshEditors", "freshTextChars",
                    "freshMeaningfulChars", "originalStillReply", "freshStillReply"]
                var counters: [String: Int] = [:]
                for key in allowed {
                    if let value = raw[key] as? Int, (-1...1_000_000).contains(value) {
                        counters[key] = value
                    }
                }
                NotificationDiagnostics.record("reply_confirmation", values: counters)
            }
            finishReply(
                reply,
                ok: (body["ok"] as? Bool) ?? false,
                statusUnknown: (body["unknown"] as? Bool) ?? false,
                reason: body["reason"] as? String
            )
        case "replySend":
            guard let rawID = body["requestId"] as? String,
                  let id = UUID(uuidString: rawID),
                  let reply = activeReply, reply.id == id else { return }
            sendReplyUsingNativeInput(reply)
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
