import AppKit
import WebKit
import XCTest
@testable import scarcrux_textem

@MainActor
final class ConversationCodePromptTests: XCTestCase {
    func testPromptUsesCurrentConversationAndConservativeDetector() throws {
        let current = try XCTUnwrap(URL(string: "https://messages.google.com/web/conversations/A"))
        func payload(_ texts: [String], url: String? = nil) -> [String: Any] {
            ["url": url ?? current.absoluteString, "texts": texts]
        }
        let candidate = ConversationCodePrompt(payload: payload([
            "Order 903628 shipped", "Your verification code is 4312", "Your verification code is 3854",
        ]), currentURL: current)
        XCTAssertEqual(candidate?.code, "4312")
        XCTAssertNil(ConversationCodePrompt(payload: payload(["Your PIN is 4312"],
            url: "https://messages.google.com/web/conversations/B"), currentURL: current))
        XCTAssertNil(ConversationCodePrompt(payload: payload(["You: Your PIN is 4312"]), currentURL: current))
    }

    private final class Loaded: NSObject, WKNavigationDelegate {
        let signal: XCTestExpectation
        init(_ signal: XCTestExpectation) { self.signal = signal }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { signal.fulfill() }
    }

    func testWebKitReaderIgnoresOutgoingHiddenAndWrongThread() throws {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 550, height: 400))
        let loaded = expectation(description: "synthetic conversation loaded")
        let delegate = Loaded(loaded)
        web.navigationDelegate = delegate
        web.loadHTMLString("""
          <mws-conversation-list-item><a href="/web/conversations/A" aria-selected="true">Test</a></mws-conversation-list-item>
          <mws-message-wrapper is-outgoing="false"><mws-text-message-part>Your PIN is 4312</mws-text-message-part></mws-message-wrapper>
          <mws-message-wrapper is-outgoing="true"><mws-text-message-part>My PIN is 9999</mws-text-message-part></mws-message-wrapper>
          <mws-message-wrapper hidden><mws-text-message-part>PIN 8888</mws-text-message-part></mws-message-wrapper>
          """, baseURL: URL(string: "https://textem-fixture.invalid/web/conversations/A"))
        wait(for: [loaded], timeout: 10)

        func read(_ script: String, expected: [String]) {
            let result = expectation(description: "read conversation")
            web.evaluateJavaScript(script) { value, error in
                XCTAssertNil(error)
                XCTAssertEqual((value as? [String: Any])?["texts"] as? [String], expected)
                result.fulfill()
            }
            wait(for: [result], timeout: 5)
        }
        read(ConversationCodePrompt.readScript, expected: ["Your PIN is 4312"])
        read("document.querySelector('a').href = '/web/conversations/B'; " + ConversationCodePrompt.readScript, expected: [])
        _ = delegate
    }

    func testRenderCopyPrompt() throws {
        guard let output = ProcessInfo.processInfo.environment["TEXTEM_CODE_PROMPT_SNAPSHOTS"] else {
            throw XCTSkip("Enable the prompt snapshot directory to render.")
        }
        _ = NSApplication.shared
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let bar = ConversationCodeBar(frame: NSRect(x: 0, y: 0, width: 920, height: 36))
            let window = NSWindow(contentRect: bar.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = bar
            bar.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(bar.bitmapImageRepForCachingDisplay(in: bar.bounds))
            bar.cacheDisplay(in: bar.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 300)
            XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 2, y: 2)).alphaComponent, 1, accuracy: 0.01)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("code-prompt-\(mode).png"))
            window.contentView = nil
        }
    }
}
