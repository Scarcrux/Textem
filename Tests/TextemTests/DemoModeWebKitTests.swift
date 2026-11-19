import WebKit
import XCTest
@testable import scarcrux_textem

// Runs the production demo script in WebKit on a page shaped like the parts of
// Google Messages that Textem already targets, seeded with "real" data that
// must not survive. A control page without the script keeps every real value,
// so the assertions can fail.
@MainActor
final class DemoModeWebKitTests: XCTestCase {
    private let realNames = ["Danielle Whitaker", "Marcus Oyelaran"]
    private let realText = ["Your table at Osteria is confirmed", "lockbox code is 4471, door on the left"]

    private var fixture: String {
        """
        <html><body>
        <header id="thread-title">\(realNames[0])</header>
        <mws-conversation-list-item><a href="/web/conversations/1">
          <mws-avatar><div>D</div><img src="data:image/gif;base64,R0lGODlhAQABAAAAACw="></mws-avatar>
          <span data-e2e-conversation-name>\(realNames[0])</span>
          <span data-e2e-conversation-snippet>\(realText[0])</span></a></mws-conversation-list-item>
        <mws-conversation-list-item><a href="/web/conversations/2">
          <mws-avatar><div>M</div></mws-avatar>
          <span data-e2e-conversation-name>\(realNames[1])</span>
          <span data-e2e-conversation-snippet>\(realText[1])</span></a></mws-conversation-list-item>
        <main><mws-text-message-part><div class="bubble outgoing"><span>\(realText[1])</span><span> </span><span>(edited)</span></div></mws-text-message-part>
          <div class="details">Call \(realNames[1]) at +1 (415) 555-2671 or marcus.o@example.net</div></main>
        </body></html>
        """
    }

    private func page(demo: Bool) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if demo {
            configuration.userContentController.addUserScript(WKUserScript(
                source: DemoMode.userScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web
        web.loadHTMLString(fixture, baseURL: URL(string: "https://textem-fixture.invalid/")!)
        for _ in 0..<50 where (try? await web.evaluateJavaScript("document.readyState") as? String) != "complete" {
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(300))
        return web
    }

    private func visibleText(_ web: WKWebView) async throws -> String {
        try await web.evaluateJavaScript("document.body.innerText") as? String ?? ""
    }

    func testControlPageShowsRealDataSoTheCheckCanFail() async throws {
        let text = try await visibleText(try await page(demo: false))
        for value in realNames + realText { XCTAssertTrue(text.contains(value), value) }
    }

    func testDemoHidesNamesTextNumbersEmailsAndImagesIncludingLaterContent() async throws {
        let web = try await page(demo: true)
        var text = try await visibleText(web)
        for value in realNames + realText + ["415", "2671", "4471", "marcus.o@example.net"] {
            XCTAssertFalse(text.contains(value), "leaked: \(value)")
        }
        XCTAssertTrue(text.contains("Alex Rivera") && text.contains("Jordan Lee"))
        XCTAssertTrue(text.contains("(555) 010-0199") && text.contains("alex@example.com"))
        let header = try await web.evaluateJavaScript("document.getElementById('thread-title').textContent") as? String
        XCTAssertEqual(header, "Alex Rivera", "a header repeating a real contact name is mapped to its sample")
        let initials = try await web.evaluateJavaScript(
            "Array.from(document.querySelectorAll('mws-avatar div')).map(d => d.textContent).join('')") as? String
        XCTAssertEqual(initials, "AJ")
        // Google's bubble markup inside a message survives; only the words change.
        let bubble = try await web.evaluateJavaScript(
            "(function(){var b=document.querySelector('mws-text-message-part .bubble.outgoing');return b ? b.textContent.trim() : 'missing';})()") as? String
        XCTAssertEqual(bubble, "Hey! Are we still on for tonight?")
        let imageVisibility = try await web.evaluateJavaScript(
            "getComputedStyle(document.querySelector('img')).visibility") as? String
        XCTAssertEqual(imageVisibility, "hidden")

        // Google renders more rows and messages later (scrolling, opening a thread).
        _ = try await web.evaluateJavaScript("""
            var item = document.querySelector('mws-conversation-list-item').cloneNode(true);
            item.querySelector('[data-e2e-conversation-name]').textContent = 'Priya Venkataraman';
            item.querySelector('[data-e2e-conversation-snippet]').textContent = 'gate code 8812';
            document.body.appendChild(item);
            var part = document.createElement('mws-text-message-part');
            part.textContent = 'meet me at 14 Hawthorne Rd';
            document.querySelector('main').appendChild(part); true;
            """)
        try await Task.sleep(for: .milliseconds(400))
        text = try await visibleText(web)
        for value in ["Priya Venkataraman", "gate code 8812", "14 Hawthorne Rd"] {
            XCTAssertFalse(text.contains(value), "late content leaked: \(value)")
        }
    }

    func testCapturesArePrivate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("textem-demo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try DemoMode.save(png: Data([0x89, 0x50]), in: root)
        let file = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        let folder = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int
        XCTAssertEqual(file, 0o600); XCTAssertEqual(folder, 0o700)
    }
}
