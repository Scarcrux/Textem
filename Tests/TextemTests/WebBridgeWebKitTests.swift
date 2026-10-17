import WebKit
import XCTest
@testable import scarcrux_textem

// Run the production bridge in WebKit. Empty e2e markers reproduce the live
// rows=0/domRows=25 failure; a bad-origin row must remain excluded.
@MainActor
final class WebBridgeWebKitTests: XCTestCase {
    private final class Collector: NSObject, WKScriptMessageHandler {
        var snapshot: [[String: Any]] = []
        var ready: XCTestExpectation?
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  body["type"] as? String == "snapshot" else { return }
            snapshot = body["rows"] as? [[String: Any]] ?? []
            ready?.fulfill()
            ready = nil
        }
    }

    func testEmptyMarkersProduceRoutedUnreadEventAndRejectExternalRow() async throws {
        let collector = Collector()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(collector, name: WebBridge.handlerName)
        configuration.userContentController.addUserScript(WKUserScript(
            source: WebBridge.userScript, injectionTime: .atDocumentEnd,
            forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: configuration)
        let baseline = expectation(description: "baseline snapshot")
        collector.ready = baseline
        web.loadHTMLString("""
        <html><body>
        <mws-conversation-list-item>
          <a data-e2e-conversation="" data-e2e-is-unread="false" href="/web/conversations/A">
            <span data-e2e-conversation-name>Example</span>
            <span data-e2e-conversation-snippet>Baseline</span>
          </a>
        </mws-conversation-list-item>
        <mws-conversation-list-item>
          <a data-e2e-conversation="evil" href="https://other.invalid/web/conversations/B">
            <span data-e2e-conversation-name>Other</span>
          </a>
        </mws-conversation-list-item>
        </body></html>
        """, baseURL: URL(string: "https://textem-fixture.invalid/web/conversations")!)
        await fulfillment(of: [baseline], timeout: 15)
        XCTAssertEqual(collector.snapshot.count, 1)
        XCTAssertEqual(collector.snapshot.first?["id"] as? String, "A")
        var tracker = ConversationActivityTracker()
        func rows(_ raw: [[String: Any]]) -> [ConversationSnapshot] {
            raw.compactMap {
                guard let id = $0["id"] as? String,
                      let fingerprint = $0["fingerprint"] as? String else { return nil }
                return ConversationSnapshot(id: id, sender: "", snippet: "",
                    fingerprint: fingerprint, isUnread: ($0["unread"] as? Bool) ?? false)
            }
        }
        XCTAssertTrue(tracker.update(rows(collector.snapshot)).isEmpty)
        let changed = expectation(description: "incoming unread snapshot")
        collector.ready = changed
        _ = try await web.evaluateJavaScript("""
        document.querySelector('[data-e2e-conversation-snippet]').textContent = 'Incoming';
        document.querySelector('a').setAttribute('data-e2e-is-unread', 'true');
        true;
        """)
        await fulfillment(of: [changed], timeout: 5)
        XCTAssertEqual(tracker.update(rows(collector.snapshot)).map(\.id), ["A"])
    }
}
