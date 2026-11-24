import AppKit
import WebKit
import XCTest
@testable import scarcrux_textem

@MainActor
final class ConversationCodePromptTests: XCTestCase {
    func testPromptUsesCurrentConversationAndConservativeDetector() throws {
        let current = try XCTUnwrap(URL(string: "https://messages.google.com/web/conversations/A"))
        func payload(_ texts: [String], url: String? = nil) -> [String: Any] {
            ["url": url ?? current.absoluteString, "messages": texts.enumerated().map {
                ["index": $0.offset, "text": $0.element, "timeMS": 1_700_000_000_000] as [String: Any]
            }]
        }
        let candidate = ConversationCodePrompt(payload: payload([
            "Order 903628 shipped", "Your verification code is 4312", "Your verification code is 3854",
        ]), currentURL: current)
        XCTAssertEqual(candidate?.code, "4312")
        XCTAssertEqual(candidate?.receivedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(candidate?.title(at: Date(timeIntervalSince1970: 1_700_000_120)).contains("unavailable") == false)
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
          <mws-message-wrapper is-outgoing="false"><time datetime="2023-11-14T22:13:20Z"></time><mws-text-message-part>Your PIN is 4312</mws-text-message-part></mws-message-wrapper>
          <mws-message-wrapper is-outgoing="true"><mws-text-message-part>My PIN is 9999</mws-text-message-part></mws-message-wrapper>
          <mws-message-wrapper hidden><mws-text-message-part>PIN 8888</mws-text-message-part></mws-message-wrapper>
          """, baseURL: URL(string: "https://textem-fixture.invalid/web/conversations/A"))
        wait(for: [loaded], timeout: 10)

        func read(_ script: String, expected: [String]) {
            let result = expectation(description: "read conversation")
            web.evaluateJavaScript(script) { value, error in
                XCTAssertNil(error)
                let entries = (value as? [String: Any])?["messages"] as? [[String: Any]]
                XCTAssertEqual(entries?.compactMap { $0["text"] as? String }, expected)
                if !expected.isEmpty {
                    XCTAssertEqual(entries?.first?["timeMS"] as? Double, 1_700_000_000_000)
                }
                result.fulfill()
            }
            wait(for: [result], timeout: 5)
        }
        read(ConversationCodePrompt.readScript, expected: ["Your PIN is 4312"])
        let googleURL = try XCTUnwrap(URL(string: "https://messages.google.com/web/conversations/A"))
        let prompt = try XCTUnwrap(ConversationCodePrompt(payload: [
            "url": googleURL.absoluteString, "messages": [["index": 0, "text": "Your PIN is 4312"]],
        ], currentURL: googleURL))
        // Exercise the exact script against a non-network fixture.
        let reveal = try XCTUnwrap(prompt.revealScript).replacingOccurrences(of: "messages.google.com", with: "textem-fixture.invalid")
        let revealed = expectation(description: "reveal exact message")
        web.evaluateJavaScript(reveal) { value, error in
            XCTAssertNil(error)
            XCTAssertEqual(value as? Bool, true)
            revealed.fulfill()
        }
        wait(for: [revealed], timeout: 5)
        let stale = expectation(description: "reject changed message at same position")
        web.evaluateJavaScript("document.querySelector('mws-text-message-part').textContent = 'PIN 4891'; " + reveal) { value, error in
            XCTAssertNil(error)
            XCTAssertEqual(value as? Bool, false)
            stale.fulfill()
        }
        wait(for: [stale], timeout: 5)
        read("document.querySelector('a').href = '/web/conversations/B'; " + ConversationCodePrompt.readScript, expected: [])
        _ = delegate
    }

    func testGlobalShortcutCodeExpiresAtThreeMinutes() {
        let received = ContinuousClock.now
        let code = RecentVerificationCode(code: "4312", receivedAt: received)
        XCTAssertNil(code.freshValue(at: received.advanced(by: .seconds(-1))))
        XCTAssertEqual(code.freshValue(at: received.advanced(by: .seconds(179))), "4312")
        XCTAssertNil(code.freshValue(at: received.advanced(by: .seconds(180))))
    }

    func testRenderCopyPrompt() throws {
        guard let output = ProcessInfo.processInfo.environment["TEXTEM_CODE_PROMPT_SNAPSHOTS"] else {
            throw XCTSkip("Enable the prompt snapshot directory to render.")
        }
        _ = NSApplication.shared
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let bar = ConversationCodeBar(frame: NSRect(x: 0, y: 0, width: 920, height: 36))
            bar.update(title: "Verification code · 2 min. ago", reset: true)
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
