import AppKit
import AuthenticationServices
import Foundation
import Testing
import NativeAutoFillCore
import NativeAutoFillProvider
@testable import scarcrux_textem

// Codes from texts that arrive in Textem's Google Messages window: detection,
// storage, the AutoFill list, and the Copy Code notification action. Every
// positive case has a negative twin that must stay silent.
@Suite("Received verification codes")
struct ReceivedCodeTests {
    let time = Date(timeIntervalSince1970: 2_000_000)
    let account = UUID()

    @Test func detectsCommonVerificationTexts() {
        let cases: [(String, String)] = [
            ("Your verification code is 482913.", "482913"),
            ("G-482913 is your Google verification code.", "482913"),
            ("Use 7731 to sign in to Example. Don't share it.", "7731"),
            ("Your Bank security code: 55102938. Expires in 10 minutes.", "55102938"),
            ("123456 is your one-time passcode", "123456"),
        ]
        for (text, code) in cases {
            #expect(CodeDetector.detect(text) == .init(code: code, domain: nil), "\(text)")
        }
        #expect(CodeDetector.detect("Your code is 004321\n@example.com #004321") == .init(code: "004321", domain: "example.com"))
    }

    @Test func staysSilentOnLookalikes() {
        for text in [
            "Your order 482913 has shipped",                  // no verification wording
            "Shipping update: parcel 48291 is out for delivery", // "pin" inside "shipping"
            "Use promo code 4821 for 20% off",                // marketing code
            "Your code is 1234. Questions? Call 1800 555",    // two candidates
            "Your code is 12345678901",                       // too long
            "Your code is 123",                               // too short
            "Login alert: $1250.00 charged",                  // amount
            "Call 555-1234 to verify your account",           // phone number
            "Your code is 004321\n@example..com #004321",     // malformed footer never downgraded
            "",
        ] {
            #expect(CodeDetector.detect(text) == nil, "\(text)")
        }
    }

    @Test func anySiteCodesAreListOnlyAndExpire() throws {
        let open = try #require(CodeSample(detection: .init(code: "482913", domain: nil), accountID: account,
                                           receivedAt: time, consent: true))
        let bound = try #require(CodeSample(detection: .init(code: "004321", domain: "example.com"), accountID: account,
                                            receivedAt: time.addingTimeInterval(-10), consent: true))
        #expect(!open.isDomainBound)
        // Never an inline suggestion, never in the OS identity index.
        #expect(CodePolicy.select([open], domains: ["example.com"], now: time) == nil)
        #expect(CodeIndexEntry.project([open, bound], now: time).map(\.domain) == ["example.com"])
        // The list: the site's own code first, then any-site codes newest first.
        #expect(CodePolicy.offers([open, bound], domains: ["example.com"], now: time) == [bound, open])
        #expect(CodePolicy.offers([open, bound], domains: [], now: time) == [open])
        #expect(CodePolicy.offers([open], domains: [], now: time.addingTimeInterval(180)).isEmpty)
        #expect(CodePolicy.revalidate([open], id: open.id, domains: [], now: time.addingTimeInterval(179)) == open)
        #expect(CodePolicy.revalidate([open], id: open.id, domains: [], now: time.addingTimeInterval(180)) == nil)
        #expect(CodeSample(detection: .init(code: "482913", domain: nil), accountID: account, receivedAt: time, consent: false) == nil)
    }

    @MainActor final class Storage: CodeStorage {
        var data: Data?
        func read() throws -> Data? { data }
        func write(_ data: Data) throws { self.data = data }
        func delete() throws { data = nil }
    }

    @Test @MainActor func vaultStoresObservedCodesOnceAndOnlyWhenEnabled() throws {
        let storage = Storage()
        let vault = CodeVault(storage: storage)
        let text = "Your verification code is 482913."
        #expect(throws: CodeVaultError.disabled) {
            try vault.ingestObserved(accountID: account, conversation: "c1", message: text, observedAt: time, now: time)
        }
        try vault.enable()
        #expect(try vault.ingestObserved(accountID: account, conversation: "c1", message: "Your order shipped",
                                         observedAt: time, now: time) == nil)
        let stored = try #require(try vault.ingestObserved(accountID: account, conversation: "c1", message: text,
                                                           observedAt: time, now: time))
        #expect(stored.code == "482913" && !stored.isDomainBound)
        // The same row re-reported later (page reload) is not a fresh code.
        #expect(try vault.ingestObserved(accountID: account, conversation: "c1", message: text,
                                         observedAt: time.addingTimeInterval(30), now: time.addingTimeInterval(30)) == nil)
        // Persisted state round-trips through the strict loader with no phone link.
        let reread = CodeVault(storage: storage)
        #expect(try reread.eligible(now: time.addingTimeInterval(1)).map(\.code) == ["482913"])
        #expect(try reread.readiness(now: time).eligible == 1)
        #expect(try reread.eligible(now: time.addingTimeInterval(180)).isEmpty)
        try reread.removeAccount(account)
        #expect(try reread.eligible(now: time).isEmpty)
    }

    @Test func onlyIncomingChangedRowsAfterTheBaselineCount() {
        func row(_ id: String, _ snippet: String, unread: Bool = true) -> ConversationSnapshot {
            ConversationSnapshot(id: id, sender: "Example", snippet: snippet, fingerprint: "Example|" + snippet, isUnread: unread)
        }
        var tracker = ConversationActivityTracker()
        _ = tracker.update([row("a", "Your code is 111111")])        // launch baseline
        #expect(ReceivedCodes.detect(in: tracker.changedRows).rows.isEmpty)
        _ = tracker.update([row("a", "Your code is 111111"), row("b", "You: my code is 222222"),
                            row("c", "Your code is 333333", unread: false)])
        let found = ReceivedCodes.detect(in: tracker.changedRows)
        #expect(found.rows.map(\.conversation) == ["c"])   // read thread still counts; own text never does
        #expect(found.code(for: "c") == "333333" && found.code(for: "b") == nil)
    }

    @Test @MainActor func listSheetFillsTheChosenAnySiteCode() throws {
        guard #available(macOS 15, *) else { return }
        _ = NSApplication.shared
        let first = try #require(CodeSample(detection: .init(code: "111111", domain: nil), accountID: account,
                                            receivedAt: time.addingTimeInterval(-60), consent: true))
        let second = try #require(CodeSample(detection: .init(code: "222222", domain: nil), accountID: account,
                                             receivedAt: time, consent: true))
        let controller = CredentialProvider()
        var completed: [String?] = []
        controller.readSamples = { [first, second] }; controller.now = { time }
        controller.testCompletion = { completed.append($0) }
        // Real Safari requests may carry no service identifier at all.
        controller.prepareOneTimeCodeCredentialList(for: [])
        let stack = try #require(controller.view.subviews.first as? NSStackView)
        let buttons = stack.arrangedSubviews.flatMap { ($0 as? NSStackView)?.arrangedSubviews ?? [$0] }.compactMap { $0 as? NSButton }
        let primary = try #require(buttons.first { $0.identifier?.rawValue == "fill-code" })
        let other = try #require(buttons.first { $0.identifier?.rawValue == "fill-code-1" })
        #expect(primary.title == "Fill 222222" && other.title == "Fill 111111")   // newest first
        other.performClick(nil)
        #expect(completed == ["111111"])
        // An inline request for a site never surfaces an any-site code.
        controller.prepareInterfaceToProvideCredential(for: ASOneTimeCodeCredentialRequest(credentialIdentity:
            ASOneTimeCodeCredentialIdentity(serviceIdentifier: .init(identifier: "example.com", type: .domain),
                                            label: "x", recordIdentifier: second.id.uuidString)))
        controller.fillCode()
        #expect(completed == ["111111"])
    }

    @Test @MainActor func copyCodeActionCopiesConcealedAndExpires() {
        let manager = NotificationManager.shared
        let pasteboard = NSPasteboard(name: .init("textem.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally(); manager.clock = Date.init; manager.pasteboard = .general }
        var now = time
        manager.clock = { now }; manager.pasteboard = pasteboard
        manager.rememberCode("482913", forNotification: "n1")
        #expect(manager.copyCode(forNotification: "n1"))
        #expect(pasteboard.string(forType: .string) == "482913")
        #expect(pasteboard.types?.contains(CodeClipboard.concealed) == true)
        pasteboard.clearContents()
        now = time.addingTimeInterval(NotificationManager.codeLifetime)
        #expect(!manager.copyCode(forNotification: "n1"))
        #expect(pasteboard.string(forType: .string) == nil)
        #expect(!manager.copyCode(forNotification: "unknown"))
    }
}
