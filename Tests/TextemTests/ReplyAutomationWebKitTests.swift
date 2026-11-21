import WebKit
import XCTest
@testable import scarcrux_textem

// Runs the EXACT inline-reply script the app injects (ReplyAutomation.script)
// inside a real WKWebView against a fixture page that reproduces the DOM
// contract the script depends on: conversation rows carrying
// a[data-e2e-conversation], route change on click, one composer per open
// thread, and a Send button that enables on input. Fixture knobs break each
// assumption in turn so every fail-closed branch is observed, not just reasoned.
//
// What this proves: the script's own targeting, ordering, fail-closed and
// reporting logic, and the app-side evaluation contract. What it cannot prove:
// that Google's live markup still matches these selectors — that still needs
// one real end-to-end message.
@MainActor
final class ReplyAutomationWebKitTests: XCTestCase {
    // Keep deliberate non-confirmation cases fast. Successful sends get more
    // time for the native click and WebKit's observation of the composer clear.
    private static let expectedNoConfirmationMilliseconds = 800

    // .invalid (RFC 2606) origin: nothing here can reach Google or any network.
    private static let origin = "https://textem-fixture.invalid"

    private static let fixtureHTML = """
    <!doctype html><html><body>
    <nav>
      <mws-conversation-list-item><a data-e2e-conversation="" href="/web/conversations/A">Alpha</a></mws-conversation-list-item>
      <mws-conversation-list-item><a data-e2e-conversation="" href="/web/conversations/B">Bravo</a></mws-conversation-list-item>
    </nav>
    <main id="thread"></main>
    <button id="unrelated" data-e2e-send-button>Unrelated action</button>
    <script>
    window.__fixture = { navigateOnClick: true, renderComposer: true, acceptText: true,
                         clearOnSend: true, clearDelayMS: 0, hijackRouteOnInput: null,
                         measurementFirst: false, modernSendMarker: false,
                         hiddenSendFirst: false, sendDisabled: false,
                         ambiguousSend: false, omitSend: false, richEditor: false,
                         requireTrustedSend: true };
    window.__sent = []; window.__clicks = []; window.__sendTrust = [];
    document.getElementById('unrelated').addEventListener('click', function() {
      __sent.push({ thread:'outside' });
    });
    function currentConv() { var m = location.pathname.match(/conversations\\/([^/]+)/); return m ? m[1] : null; }
    function renderThread() {
      var t = document.getElementById('thread'); t.innerHTML = '';
      var id = currentConv();
      if (!id || !__fixture.renderComposer) return;
      var c = document.createElement('mws-message-compose');
      var box = document.createElement(__fixture.richEditor ? 'div' : 'textarea');
      if (__fixture.richEditor) box.setAttribute('contenteditable', 'true');
      else box.setAttribute('data-e2e-message-input-box', '');
      function composerText() { return 'value' in box ? box.value : (box.textContent || ''); }
      function clearComposer() { if ('value' in box) box.value = ''; else box.textContent = ''; }
      var send = document.createElement('button');
      send.setAttribute(__fixture.modernSendMarker ? 'data-e2e-send-text-button' : 'data-e2e-send-button', '');
      send.disabled = true; send.textContent = 'Send';
      box.addEventListener('input', function () {
        if (!__fixture.acceptText) clearComposer();
        if (__fixture.hijackRouteOnInput) history.pushState({}, '', '/web/conversations/' + __fixture.hijackRouteOnInput);
        send.disabled = __fixture.sendDisabled || composerText().length === 0;
      });
      send.addEventListener('click', function (event) {
        __sendTrust.push(event.isTrusted);
        if (__fixture.requireTrustedSend && !event.isTrusted) return;
        __sent.push({ thread: id, route: currentConv(), text: composerText() });
        if (__fixture.clearOnSend) {
          if (__fixture.clearDelayMS) setTimeout(clearComposer, __fixture.clearDelayMS);
          else clearComposer();
        }
      });
      if (__fixture.measurementFirst) {
        var measurement = document.createElement('textarea');
        measurement.setAttribute('data-e2e-message-input-box', '');
        measurement.hidden = true;
        c.appendChild(measurement);
      }
      c.appendChild(box);
      if (__fixture.hiddenSendFirst) {
        var hiddenSend = send.cloneNode(true);
        var hiddenContainer = document.createElement('div');
        hiddenContainer.style.display = 'none'; hiddenSend.disabled = false;
        hiddenSend.addEventListener('click', function() { __sent.push({thread:'hidden'}); });
        hiddenContainer.appendChild(hiddenSend); c.appendChild(hiddenContainer);
      }
      if (!__fixture.omitSend) c.appendChild(send);
      if (__fixture.ambiguousSend) c.appendChild(send.cloneNode(true));
      t.appendChild(c);
    }
    document.querySelectorAll('a[data-e2e-conversation]').forEach(function (a) {
      a.addEventListener('click', function (e) {
        e.preventDefault();
        __clicks.push(new URL(a.href).pathname.split('/').pop());
        if (!__fixture.navigateOnClick) return;
        history.pushState({}, '', a.getAttribute('href'));
        renderThread();
      });
    });
    renderThread();
    </script></body></html>
    """

    // MARK: Harness

    @MainActor private final class ResultCollector: NSObject, WKScriptMessageHandler {
        var results: [[String: Any]] = []
        var expectation: XCTestExpectation?
        weak var webView: WKWebView?
        var useNativeInput = true
        var nativeDispatched = false
        var sendRequests = 0
        var sendTargets = 0

        var diagnosticSummary: String {
            let result = results.first ?? [:]
            return ReplyAutomationWebKitTests.diagnosticSummary(result)
                + " results=\(results.count) sendRequests=\(sendRequests) sendTargets=\(sendTargets)"
                + " nativeDispatched=\(nativeDispatched)"
        }
        var nativeRequestID = "req-1"
        var invalidateRouteAtNativeSend = false
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if body["type"] as? String == "replySend", let webView {
                sendRequests += 1
                let id = ReplyAutomation.jsonString(nativeRequestID)!
                let invalidate = invalidateRouteAtNativeSend
                    ? "history.pushState({}, '', '/web/conversations/Z');" : ""
                webView.evaluateJavaScript("\(invalidate) window.__textemReplySendTarget(\(id))") {
                    [weak self, weak webView] result, _ in
                    guard let self, let webView, let target = result as? [String: Any] else { return }
                    self.sendTargets += 1
                    if self.useNativeInput {
                        self.nativeDispatched = NativeWebClick.send(in: webView, target: target)
                    } else {
                        // Negative control: this was our old production action.
                        webView.evaluateJavaScript("""
                        (function() {
                          var t = window.__textemReplySendTarget('req-1');
                          if (t) document.elementFromPoint(t.x, t.y).closest('button').click();
                        })()
                        """, completionHandler: nil)
                    }
                }
                return
            }
            guard body["type"] as? String == "replyResult" else { return }
            results.append(body)
            expectation?.fulfill()
        }
    }

    @MainActor private final class LoadWaiter: NSObject, WKNavigationDelegate {
        let loaded: XCTestExpectation
        init(_ loaded: XCTestExpectation) { self.loaded = loaded }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
    }

    @MainActor private final class Box { var result: Any?; var error: Error? }

    private static func diagnosticSummary(_ result: [String: Any]) -> String {
        let reason = result["reason"] as? String ?? (result.isEmpty ? "no-result" : "none")
        let counters = (result["diagnostics"] as? [String: Any] ?? [:])
            .compactMap { key, value in (value as? NSNumber).map { (key, $0) } }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: ", ")
        return "reason=\(reason) diagnostics=[\(counters)]"
    }

    private struct Outcome {
        var result: [String: Any]
        var resultCount: Int
        var evaluationError: Error?
        var sent: [[String: Any]]
        var clicks: [String]
        var composerValues: [String]
        var sendTrust: [Bool]
        var nativeDispatched: Bool
        var diagnostics: String
    }

    private func evaluate(_ webView: WKWebView, _ source: String) -> Box {
        let done = expectation(description: "evaluate")
        let box = Box()
        webView.evaluateJavaScript(source) { result, error in
            box.result = result; box.error = error; done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return box
    }

    private func runReply(target: String, text: String = "On my way",
                          startOpen: String = "B", fixture: String = "{}",
                          nativeInput: Bool = true, zoom: Double = 1,
                          nativeRequestID: String = "req-1",
                          invalidateRouteAtNativeSend: Bool = false,
                          confirmMilliseconds: Int = 2_500) throws -> Outcome {
        let collector = ResultCollector()
        let config = WKWebViewConfiguration()
        config.userContentController.add(collector, name: WebBridge.handlerName)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.pageZoom = zoom
        collector.webView = webView
        collector.useNativeInput = nativeInput
        collector.nativeRequestID = nativeRequestID
        collector.invalidateRouteAtNativeSend = invalidateRouteAtNativeSend
        let window = NSWindow(
            contentRect: NSRect(x: 20, y: 20, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Textem reply fixture"
        window.contentView = webView
        // An occluded WebKit page can throttle its JS timers beyond the
        // harness deadline (observed in the missing-composer negative case).
        // Keep only this fixture visible without activating the test app.
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close() }

        let loaded = expectation(description: "fixture loaded")
        let waiter = LoadWaiter(loaded)
        webView.navigationDelegate = waiter
        webView.loadHTMLString(Self.fixtureHTML,
                               baseURL: URL(string: "\(Self.origin)/web/conversations/\(startOpen)")!)
        wait(for: [loaded], timeout: 10)

        let setup = evaluate(webView, "Object.assign(window.__fixture, \(fixture)); true")
        XCTAssertNil(setup.error, "fixture setup failed: \(String(describing: setup.error))")

        let timeouts = ReplyAutomation.Timeouts(
            selectMilliseconds: 1_500, sendMilliseconds: 800, confirmMilliseconds: confirmMilliseconds)
        let script = try XCTUnwrap(ReplyAutomation.script(
            requestID: "req-1", text: text, conversationID: target, timeouts: timeouts))
        let posted = expectation(description: "replyResult")
        collector.expectation = posted
        // Evaluate exactly as WebViewController does: the raw script, no suffix.
        let evaluation = evaluate(webView, script)
        XCTAssertEqual(XCTWaiter.wait(for: [posted], timeout: 8), .completed, collector.diagnosticSummary)

        // Let any stray second post land before counting (there must be one).
        let settle = expectation(description: "settle"); settle.isInverted = true
        wait(for: [settle], timeout: 0.4)

        let state = evaluate(webView, """
            JSON.stringify({ sent: __sent, clicks: __clicks, sendTrust:__sendTrust,
              values: Array.from(document.querySelectorAll('textarea, [contenteditable="true"]'))
                .map(function (t) { return 'value' in t ? t.value : (t.textContent || ''); }) })
            """)
        let json = try XCTUnwrap((state.result as? String)?.data(using: .utf8), collector.diagnosticSummary)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any], collector.diagnosticSummary)
        _ = waiter
        return Outcome(
            result: collector.results.first ?? [:],
            resultCount: collector.results.count,
            evaluationError: evaluation.error,
            sent: decoded["sent"] as? [[String: Any]] ?? [],
            clicks: decoded["clicks"] as? [String] ?? [],
            composerValues: decoded["values"] as? [String] ?? [],
            sendTrust: decoded["sendTrust"] as? [Bool] ?? [],
            nativeDispatched: collector.nativeDispatched,
            diagnostics: collector.diagnosticSummary + " fixtureSends=\((decoded["sent"] as? [Any] ?? []).count)")
    }

    // MARK: Tests

    func testRepliesIntoTheNotifiedThreadNotTheOpenOne() throws {
        let o = try runReply(target: "A", startOpen: "B")
        XCTAssertTrue(o.nativeDispatched, o.diagnostics)
        XCTAssertEqual(o.result["ok"] as? Bool, true, o.diagnostics)
        XCTAssertEqual(o.result["requestId"] as? String, "req-1", o.diagnostics)
        XCTAssertEqual(o.clicks, ["A"], o.diagnostics)
        XCTAssertEqual(o.sent.count, 1, o.diagnostics)
        XCTAssertEqual(o.sent.first?["thread"] as? String, "A", "typed into the wrong thread's composer; \(o.diagnostics)")
        XCTAssertEqual(o.sent.first?["text"] as? String, "On my way", o.diagnostics)
        XCTAssertEqual(o.resultCount, 1, o.diagnostics)
        XCTAssertEqual(o.sendTrust, [true], o.diagnostics)
    }

    func testSyntheticClickIsRejectedByObservedTrustGate() throws {
        let o = try runReply(target: "A", fixture:
            "{measurementFirst:true, modernSendMarker:true, hiddenSendFirst:true, richEditor:true}",
            nativeInput: false, confirmMilliseconds: Self.expectedNoConfirmationMilliseconds)
        XCTAssertEqual(o.sendTrust, [false], o.diagnostics)
        XCTAssertTrue(o.sent.isEmpty, o.diagnostics)
        XCTAssertEqual(o.result["reason"] as? String, "submission-unconfirmed", o.diagnostics)
    }

    func testNativeSendUsesViewportCoordinatesAtZoom() throws {
        let o = try runReply(target: "A", fixture:
            "{measurementFirst:true, modernSendMarker:true, hiddenSendFirst:true, richEditor:true}",
            zoom: 1.5)
        XCTAssertEqual(o.result["ok"] as? Bool, true, o.diagnostics)
        XCTAssertEqual(o.sendTrust, [true], o.diagnostics)
        XCTAssertEqual(o.sent.first?["thread"] as? String, "A", o.diagnostics)
    }

    func testNativeSendRejectsInvalidGeometryAndDetachedView() {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertFalse(NativeWebClick.send(in: web, target: [
            "x": 50, "y": 50, "viewportWidth": 100, "viewportHeight": 100]), "Detached test view accepted a native click")
        XCTAssertFalse(NativeWebClick.send(in: web, target: [
            "x": -1, "y": 50, "viewportWidth": 100, "viewportHeight": 100]), "Invalid fixture geometry accepted a native click")
    }

    func testNativeSendRejectsMismatchedRequestNonce() throws {
        let o = try runReply(target: "A", nativeRequestID: "other-request",
                             confirmMilliseconds: Self.expectedNoConfirmationMilliseconds)
        XCTAssertFalse(o.nativeDispatched, o.diagnostics)
        XCTAssertTrue(o.sent.isEmpty, o.diagnostics)
        XCTAssertTrue(o.sendTrust.isEmpty, o.diagnostics)
    }

    func testNativeSendRevalidatesRouteBeforeGettingClickTarget() throws {
        let o = try runReply(target: "A", invalidateRouteAtNativeSend: true,
                             confirmMilliseconds: Self.expectedNoConfirmationMilliseconds)
        XCTAssertFalse(o.nativeDispatched, o.diagnostics)
        XCTAssertTrue(o.sent.isEmpty, o.diagnostics)
        XCTAssertTrue(o.sendTrust.isEmpty, o.diagnostics)
    }

    func testAlreadyOpenThreadIsNotReclicked() throws {
        let o = try runReply(target: "A", startOpen: "A")
        XCTAssertEqual(o.result["ok"] as? Bool, true, o.diagnostics)
        XCTAssertEqual(o.clicks, [], o.diagnostics)
        XCTAssertEqual(o.sent.first?["thread"] as? String, "A", o.diagnostics)
    }

    func testObservedComposerSkipsMeasurementFieldAndHiddenSendButton() throws {
        let o = try runReply(target: "A", fixture:
            "{measurementFirst:true, modernSendMarker:true, hiddenSendFirst:true, richEditor:true}")
        XCTAssertEqual(o.result["ok"] as? Bool, true, o.diagnostics)
        XCTAssertEqual(o.sent.count, 1, o.diagnostics)
        XCTAssertEqual(o.sent.first?["thread"] as? String, "A", o.diagnostics)
        XCTAssertEqual(o.sent.first?["text"] as? String, "On my way", o.diagnostics)
        XCTAssertEqual(o.composerValues, ["", ""], "hidden sizing field must remain untouched; \(o.diagnostics)")
    }

    func testDisabledModernSendDoesNotClickHiddenOrUnrelatedButtons() throws {
        let o = try runReply(target: "A", fixture:
            "{measurementFirst:true, modernSendMarker:true, hiddenSendFirst:true, sendDisabled:true, richEditor:true}")
        XCTAssertEqual(o.result["reason"] as? String, "send-button-unavailable", o.diagnostics)
        XCTAssertTrue(o.sent.isEmpty, o.diagnostics)
        XCTAssertEqual(o.composerValues, ["", "On my way"], o.diagnostics)
    }

    func testMissingScopedSendDoesNotUseUnrelatedPageButton() throws {
        let o = try runReply(target: "A", fixture: "{omitSend:true}")
        XCTAssertEqual(o.result["reason"] as? String, "send-button-unavailable", o.diagnostics)
        XCTAssertTrue(o.sent.isEmpty, o.diagnostics)
    }

    func testAmbiguousVisibleSendButtonsFailClosed() throws {
        let o = try runReply(target: "A", fixture: "{ambiguousSend:true}")
        XCTAssertEqual(o.result["reason"] as? String, "send-button-ambiguous", o.diagnostics)
        XCTAssertTrue(o.sent.isEmpty, o.diagnostics)
    }

    func testUnknownConversationFailsWithoutTouchingThePage() throws {
        let o = try runReply(target: "Z")
        XCTAssertEqual(o.result["ok"] as? Bool, false, o.diagnostics)
        XCTAssertEqual(o.result["reason"] as? String, "conversation-not-found", o.diagnostics)
        XCTAssertEqual(o.clicks, [], o.diagnostics)
        XCTAssertTrue(o.sent.isEmpty, o.diagnostics)
        XCTAssertEqual(o.resultCount, 1, o.diagnostics)
    }

    func testRouteThatNeverArrivesFailsClosedInsteadOfTypingIntoTheOpenThread() throws {
        let o = try runReply(target: "A", startOpen: "B", fixture: "{navigateOnClick: false}")
        XCTAssertEqual(o.result["reason"] as? String, "conversation-not-selected", o.diagnostics)
        XCTAssertTrue(o.sent.isEmpty, o.diagnostics)
        XCTAssertEqual(o.composerValues, [""], "text leaked into thread B's composer; \(o.diagnostics)")
    }

    func testMissingComposerFails() throws {
        let o = try runReply(target: "A", fixture: "{renderComposer: false}")
        XCTAssertEqual(o.result["reason"] as? String, "composer-not-found", o.diagnostics)
        XCTAssertTrue(o.sent.isEmpty, o.diagnostics)
    }

    func testComposerRejectingTheTextFailsBeforeSend() throws {
        let o = try runReply(target: "A", fixture: "{acceptText: false}")
        XCTAssertEqual(o.result["reason"] as? String, "composer-rejected-text", o.diagnostics)
        XCTAssertTrue(o.sent.isEmpty, o.diagnostics)
    }

    func testRouteChangingMidReplyAbortsBeforeSend() throws {
        let o = try runReply(target: "A", fixture: "{hijackRouteOnInput: 'B'}")
        XCTAssertEqual(o.result["reason"] as? String, "conversation-changed", o.diagnostics)
        XCTAssertTrue(o.sent.isEmpty, o.diagnostics)
    }

    func testUnclearedComposerReportsUnknownRatherThanFailure() throws {
        let o = try runReply(target: "A", fixture: "{clearOnSend: false}",
                             confirmMilliseconds: Self.expectedNoConfirmationMilliseconds)
        XCTAssertEqual(o.result["ok"] as? Bool, false, o.diagnostics)
        XCTAssertEqual(o.result["unknown"] as? Bool, true, "Send was pressed; must not claim 'not sent'; \(o.diagnostics)")
        XCTAssertEqual(o.result["reason"] as? String, "submission-unconfirmed", o.diagnostics)
        XCTAssertEqual(o.sent.count, 1, o.diagnostics)
        let counters = try XCTUnwrap(o.result["diagnostics"] as? [String: Any], o.diagnostics)
        XCTAssertEqual(counters["originalConnected"] as? Int, 1, o.diagnostics)
        XCTAssertEqual(counters["originalStillReply"] as? Int, 1, o.diagnostics)
        XCTAssertEqual(counters["freshStillReply"] as? Int, 1, o.diagnostics)
        XCTAssertEqual(counters["routeMatches"] as? Int, 1, o.diagnostics)
        XCTAssertTrue(counters.values.allSatisfy { $0 is NSNumber },
                      "confirmation diagnostics must not contain message text or IDs; \(o.diagnostics)")
    }

    func testReplyTextIsInjectedVerbatim() throws {
        let tricky = "He said \"hi\" & it's 5\\6 </script>\nline 2\u{2028}end 😀 ' \u{0}x"
        let o = try runReply(target: "A", text: tricky)
        XCTAssertEqual(o.result["ok"] as? Bool, true, o.diagnostics)
        XCTAssertEqual(o.sent.first?["text"] as? String, tricky, o.diagnostics)
    }

    func testReplyConfirmsAfterDelayedComposerClear() throws {
        let o = try runReply(target: "A", fixture: "{clearDelayMS:1200}")
        XCTAssertEqual(o.sent.count, 1, o.diagnostics)
        XCTAssertEqual(o.sendTrust, [true], o.diagnostics)
        XCTAssertEqual(o.result["ok"] as? Bool, true, o.diagnostics)
    }

    // WebViewController treats ANY evaluateJavaScript error as a failed reply
    // and notifies "Reply not sent". The script runs asynchronously, so an
    // evaluation error here would mean a false failure notice for a reply that
    // actually goes through — inviting a duplicate resend.
    func testScriptEvaluationReportsNoErrorToTheApp() throws {
        let o = try runReply(target: "A")
        XCTAssertNil(o.evaluationError,
                     "evaluateJavaScript errored: \(String(describing: o.evaluationError)); \(o.diagnostics)")
        XCTAssertEqual(o.result["ok"] as? Bool, true, o.diagnostics)
    }
}
