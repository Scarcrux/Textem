import AppKit
import AuthenticationServices
import NativeAutoFillCore
import NativeAutoFillProvider
import WebKit
import XCTest
@testable import scarcrux_textem

// End-to-end simulation of a verification text arriving, with no phone, no
// real site and no person: a fixture inbox runs the production bridge script
// in WebKit, and the resulting rows go through the same tracker, delivery
// plan, protected vault, Copy Code action and AutoFill sheet the app uses.
//
// Not covered (needs the real world): Google's actual inbox markup, macOS
// showing the notification banner, and macOS presenting Textem Codes in Safari.
@MainActor
final class CodeArrivalSimulationTests: XCTestCase {
    private final class Collector: NSObject, WKScriptMessageHandler {
        var rows: [ConversationSnapshot] = []
        var ready: XCTestExpectation?
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], body["type"] as? String == "snapshot" else { return }
            rows = (body["rows"] as? [[String: Any]] ?? []).compactMap { row in
                guard let id = row["id"] as? String, let fingerprint = row["fingerprint"] as? String else { return nil }
                return ConversationSnapshot(id: id, sender: row["sender"] as? String ?? "",
                                            snippet: row["snippet"] as? String ?? "",
                                            fingerprint: fingerprint, isUnread: (row["unread"] as? Bool) ?? false)
            }
            ready?.fulfill(); ready = nil
        }
    }

    private final class Storage: CodeStorage {
        var data: Data?
        func read() throws -> Data? { data }
        func write(_ data: Data) throws { self.data = data }
        func delete() throws { data = nil }
    }

    private func row(_ id: String, _ name: String, _ snippet: String, unread: Bool) -> String {
        """
        <mws-conversation-list-item id="row-\(id)">
          <a data-e2e-conversation="" data-e2e-is-unread="\(unread)" href="/web/conversations/\(id)">
            <span data-e2e-conversation-name>\(name)</span>
            <span data-e2e-conversation-snippet>\(snippet)</span>
          </a>
        </mws-conversation-list-item>
        """
    }

    func testTextArrivingInTheInboxReachesCopyCodeAndAutoFill() async throws {
        let collector = Collector(), configuration = WKWebViewConfiguration()
        configuration.userContentController.add(collector, name: WebBridge.handlerName)
        configuration.userContentController.addUserScript(WKUserScript(source: WebBridge.userScript,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)

        // Launch: an OLD code already sits in the inbox. It must never be offered.
        let baseline = expectation(description: "baseline snapshot")
        collector.ready = baseline
        web.loadHTMLString("<html><body>"
            + row("A", "Bank", "Your verification code is 111111", unread: true)
            + row("B", "Google", "See you tomorrow", unread: false)
            + row("C", "Mom", "Dinner at 7?", unread: false)
            + "</body></html>", baseURL: URL(string: "https://textem-fixture.invalid/web/conversations")!)
        await fulfillment(of: [baseline], timeout: 15)
        var tracker = ConversationActivityTracker()
        XCTAssertEqual(collector.rows.count, 3)
        XCTAssertTrue(tracker.update(collector.rows).isEmpty)
        let launch = ReceivedCodes.plan(events: [], changed: tracker.changedRows, notify: true, offerCopy: true)
        XCTAssertTrue(launch.store.isEmpty, "an old code in the inbox was offered at launch")

        // A real-looking verification text arrives in thread B (unread), and
        // the person's own message containing digits is sent in thread C.
        let arrived = expectation(description: "incoming code snapshot")
        collector.ready = arrived
        _ = try await web.evaluateJavaScript("""
        var b = document.querySelector('#row-B a');
        b.setAttribute('data-e2e-is-unread', 'true');
        b.querySelector('[data-e2e-conversation-snippet]').textContent = 'G-482913 is your Google verification code.';
        document.querySelector('#row-C [data-e2e-conversation-snippet]').textContent = 'You: my old PIN was 9999';
        true;
        """)
        await fulfillment(of: [arrived], timeout: 5)
        let now = Date()
        let events = tracker.update(collector.rows)
        let plan = ReceivedCodes.plan(events: events, changed: tracker.changedRows, notify: true, offerCopy: true)

        // Notification: the new-message banner for B carries Copy Code.
        XCTAssertEqual(plan.messageNotifications.map(\.event.id), ["B"])
        XCTAssertEqual(plan.messageNotifications.first?.code, "482913")
        XCTAssertEqual(plan.store.map(\.conversation), ["B"], "own message or old code was stored")
        XCTAssertTrue(plan.codeNotifications.isEmpty)

        // Copy Code button → clipboard (isolated pasteboard), then it expires.
        let manager = NotificationManager.shared
        let pasteboard = NSPasteboard(name: .init("textem.sim.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally(); manager.clock = Date.init; manager.pasteboard = .general }
        var clock = now
        manager.clock = { clock }; manager.pasteboard = pasteboard
        manager.rememberCode("482913", forNotification: "sim")
        XCTAssertTrue(manager.copyCode(forNotification: "sim"))
        XCTAssertEqual(pasteboard.string(forType: .string), "482913")

        // AutoFill: stored in the protected vault, then chosen in the sheet.
        let vault = CodeVault(storage: Storage())
        try vault.enable()
        for item in plan.store {
            try vault.ingestObserved(accountID: UUID(), conversation: item.conversation, message: item.message,
                                     observedAt: now, now: now)
        }
        XCTAssertEqual(try vault.eligible(now: now).map(\.code), ["482913"])
        // A page reload re-reporting the same row 30 s later is not a new code.
        let account = UUID()
        try vault.ingestObserved(accountID: account, conversation: "R", message: "Your code is 7731", observedAt: now, now: now)
        XCTAssertNil(try vault.ingestObserved(accountID: account, conversation: "R", message: "Your code is 7731",
                                              observedAt: now.addingTimeInterval(30), now: now.addingTimeInterval(30)))
        try vault.removeAccount(account)
        guard #available(macOS 15, *) else { return }
        _ = NSApplication.shared
        let provider = CredentialProvider()
        var filled: [String?] = []
        provider.readSamples = { (try? vault.eligible(now: clock)) ?? [] }
        provider.now = { clock }
        provider.testCompletion = { filled.append($0) }
        provider.prepareOneTimeCodeCredentialList(for: [ASCredentialServiceIdentifier(identifier: "accounts.google.com", type: .domain)])
        provider.fillCode()
        XCTAssertEqual(filled, ["482913"])

        // Three minutes later nothing is offered or copied any more.
        clock = now.addingTimeInterval(180)
        XCTAssertFalse(manager.copyCode(forNotification: "sim"))
        provider.prepareOneTimeCodeCredentialList(for: [])
        provider.fillCode()
        XCTAssertEqual(filled, ["482913"])


    }

    func testCodeInTheOpenReadThreadStillOffersCopyCode() {
        var tracker = ConversationActivityTracker()
        let open = ConversationSnapshot(id: "A", sender: "Bank", snippet: "Hi", fingerprint: "Bank|Hi", isUnread: false)
        _ = tracker.update([open])
        let arrived = ConversationSnapshot(id: "A", sender: "Bank", snippet: "Your login code is 55102938",
                                           fingerprint: "Bank|code", isUnread: false)
        let events = tracker.update([arrived])
        XCTAssertTrue(events.isEmpty)   // no new-message banner for a read thread
        let plan = ReceivedCodes.plan(events: events, changed: tracker.changedRows, notify: true, offerCopy: true)
        XCTAssertEqual(plan.codeNotifications.map(\.code), ["55102938"])
        // Frontmost/muted: still stored for AutoFill, but no banner.
        let quiet = ReceivedCodes.plan(events: events, changed: tracker.changedRows, notify: false, offerCopy: true)
        XCTAssertTrue(quiet.codeNotifications.isEmpty && quiet.store.count == 1)
        // Copy Code switched off: plain banner, no code attached.
        let off = ReceivedCodes.plan(events: [arrived], changed: [arrived], notify: true, offerCopy: false)
        XCTAssertNil(off.messageNotifications.first?.code)
        XCTAssertTrue(off.codeNotifications.isEmpty)
    }
}
