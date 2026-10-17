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
    private static let fast = ReplyAutomation.Timeouts(
        selectMilliseconds: 1_500, sendMilliseconds: 800, confirmMilliseconds: 800)

    // .invalid (RFC 2606) origin: nothing here can reach Google or any network.
    private static let origin = "https://textem-fixture.invalid"

    private static let fixtureHTML = """
    <!doctype html><html><body>
    <nav>
      <mws-conversation-list-item><a data-e2e-conversation="" href="/web/conversations/A">Alpha</a></mws-conversation-list-item>
      <mws-conversation-list-item><a data-e2e-conversation="" href="/web/conversations/B">Bravo</a></mws-conversation-list-item>
    </nav>
    <main id="thread"></main>
    <script>
    window.__fixture = { navigateOnClick: true, renderComposer: true, acceptText: true,
                         clearOnSend: true, hijackRouteOnInput: null };
    window.__sent = []; window.__clicks = [];
    function currentConv() { var m = location.pathname.match(/conversations\\/([^/]+)/); return m ? m[1] : null; }
    function renderThread() {
      var t = document.getElementById('thread'); t.innerHTML = '';
      var id = currentConv();
      if (!id || !__fixture.renderComposer) return;
      var c = document.createElement('mws-message-compose');
      var box = document.createElement('textarea'); box.setAttribute('data-e2e-message-input-box', '');
      var send = document.createElement('button'); send.setAttribute('data-e2e-send-button', '');
      send.disabled = true; send.textContent = 'Send';
      box.addEventListener('input', function () {
        if (!__fixture.acceptText) box.value = '';
        if (__fixture.hijackRouteOnInput) history.pushState({}, '', '/web/conversations/' + __fixture.hijackRouteOnInput);
        send.disabled = box.value.length === 0;
      });
      send.addEventListener('click', function () {
        __sent.push({ thread: id, route: currentConv(), text: box.value });
        if (__fixture.clearOnSend) box.value = '';
      });
      c.appendChild(box); c.appendChild(send); t.appendChild(c);
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
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  body["type"] as? String == "replyResult" else { return }
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

    private struct Outcome {
        var result: [String: Any]
        var resultCount: Int
        var evaluationError: Error?
        var sent: [[String: Any]]
        var clicks: [String]
        var composerValues: [String]
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
                          startOpen: String = "B", fixture: String = "{}") throws -> Outcome {
        let collector = ResultCollector()
        let config = WKWebViewConfiguration()
        config.userContentController.add(collector, name: WebBridge.handlerName)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)

        let loaded = expectation(description: "fixture loaded")
        let waiter = LoadWaiter(loaded)
        webView.navigationDelegate = waiter
        webView.loadHTMLString(Self.fixtureHTML,
                               baseURL: URL(string: "\(Self.origin)/web/conversations/\(startOpen)")!)
        wait(for: [loaded], timeout: 10)

        let setup = evaluate(webView, "Object.assign(window.__fixture, \(fixture)); true")
        XCTAssertNil(setup.error, "fixture setup failed: \(String(describing: setup.error))")

        let script = try XCTUnwrap(ReplyAutomation.script(
            requestID: "req-1", text: text, conversationID: target, timeouts: Self.fast))
        let posted = expectation(description: "replyResult")
        collector.expectation = posted
        // Evaluate exactly as WebViewController does: the raw script, no suffix.
        let evaluation = evaluate(webView, script)
        wait(for: [posted], timeout: 8)

        // Let any stray second post land before counting (there must be one).
        let settle = expectation(description: "settle"); settle.isInverted = true
        wait(for: [settle], timeout: 0.4)

        let state = evaluate(webView, """
            JSON.stringify({ sent: __sent, clicks: __clicks,
              values: Array.from(document.querySelectorAll('textarea')).map(function (t) { return t.value; }) })
            """)
        let json = try XCTUnwrap((state.result as? String)?.data(using: .utf8))
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        _ = waiter
        return Outcome(
            result: collector.results.first ?? [:],
            resultCount: collector.results.count,
            evaluationError: evaluation.error,
            sent: decoded["sent"] as? [[String: Any]] ?? [],
            clicks: decoded["clicks"] as? [String] ?? [],
            composerValues: decoded["values"] as? [String] ?? [])
    }

    // MARK: Tests

    func testRepliesIntoTheNotifiedThreadNotTheOpenOne() throws {
        let o = try runReply(target: "A", startOpen: "B")
        XCTAssertEqual(o.result["ok"] as? Bool, true)
        XCTAssertEqual(o.result["requestId"] as? String, "req-1")
        XCTAssertEqual(o.clicks, ["A"])
        XCTAssertEqual(o.sent.count, 1)
        XCTAssertEqual(o.sent.first?["thread"] as? String, "A", "typed into the wrong thread's composer")
        XCTAssertEqual(o.sent.first?["text"] as? String, "On my way")
        XCTAssertEqual(o.resultCount, 1)
    }

    func testAlreadyOpenThreadIsNotReclicked() throws {
        let o = try runReply(target: "A", startOpen: "A")
        XCTAssertEqual(o.result["ok"] as? Bool, true)
        XCTAssertEqual(o.clicks, [])
        XCTAssertEqual(o.sent.first?["thread"] as? String, "A")
    }

    func testUnknownConversationFailsWithoutTouchingThePage() throws {
        let o = try runReply(target: "Z")
        XCTAssertEqual(o.result["ok"] as? Bool, false)
        XCTAssertEqual(o.result["reason"] as? String, "conversation-not-found")
        XCTAssertEqual(o.clicks, [])
        XCTAssertTrue(o.sent.isEmpty)
        XCTAssertEqual(o.resultCount, 1)
    }

    func testRouteThatNeverArrivesFailsClosedInsteadOfTypingIntoTheOpenThread() throws {
        let o = try runReply(target: "A", startOpen: "B", fixture: "{navigateOnClick: false}")
        XCTAssertEqual(o.result["reason"] as? String, "conversation-not-selected")
        XCTAssertTrue(o.sent.isEmpty)
        XCTAssertEqual(o.composerValues, [""], "text leaked into thread B's composer")
    }

    func testMissingComposerFails() throws {
        let o = try runReply(target: "A", fixture: "{renderComposer: false}")
        XCTAssertEqual(o.result["reason"] as? String, "composer-not-found")
        XCTAssertTrue(o.sent.isEmpty)
    }

    func testComposerRejectingTheTextFailsBeforeSend() throws {
        let o = try runReply(target: "A", fixture: "{acceptText: false}")
        XCTAssertEqual(o.result["reason"] as? String, "composer-rejected-text")
        XCTAssertTrue(o.sent.isEmpty)
    }

    func testRouteChangingMidReplyAbortsBeforeSend() throws {
        let o = try runReply(target: "A", fixture: "{hijackRouteOnInput: 'B'}")
        XCTAssertEqual(o.result["reason"] as? String, "conversation-changed")
        XCTAssertTrue(o.sent.isEmpty)
    }

    func testUnclearedComposerReportsUnknownRatherThanFailure() throws {
        let o = try runReply(target: "A", fixture: "{clearOnSend: false}")
        XCTAssertEqual(o.result["ok"] as? Bool, false)
        XCTAssertEqual(o.result["unknown"] as? Bool, true, "Send was pressed; must not claim 'not sent'")
        XCTAssertEqual(o.result["reason"] as? String, "submission-unconfirmed")
        XCTAssertEqual(o.sent.count, 1)
    }

    func testReplyTextIsInjectedVerbatim() throws {
        let tricky = "He said \"hi\" & it's 5\\6 </script>\nline 2\u{2028}end 😀 ' \u{0}x"
        let o = try runReply(target: "A", text: tricky)
        XCTAssertEqual(o.result["ok"] as? Bool, true)
        XCTAssertEqual(o.sent.first?["text"] as? String, tricky)
    }

    // WebViewController treats ANY evaluateJavaScript error as a failed reply
    // and notifies "Reply not sent". The script runs asynchronously, so an
    // evaluation error here would mean a false failure notice for a reply that
    // actually goes through — inviting a duplicate resend.
    func testScriptEvaluationReportsNoErrorToTheApp() throws {
        let o = try runReply(target: "A")
        XCTAssertNil(o.evaluationError,
                     "evaluateJavaScript errored: \(String(describing: o.evaluationError))")
        XCTAssertEqual(o.result["ok"] as? Bool, true)
    }
}
