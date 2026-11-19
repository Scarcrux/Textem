import Testing
@testable import scarcrux_textem

@Suite("Blank inbox recovery")
struct PageStallPolicyTests {
    @Test func emptyInboxReloadsOnceThenExplains() {
        #expect(PageStallPolicy.decide(path: "/web/conversations", renderedRows: 0, signInVisible: false, reloadsUsed: 0) == .reload)
        #expect(PageStallPolicy.decide(path: "/web/conversations/123", renderedRows: 0, signInVisible: false, reloadsUsed: 1) == .showError)
    }

    @Test func neverInterruptsARenderedInboxSignInOrPairing() {
        #expect(PageStallPolicy.decide(path: "/web/conversations", renderedRows: 25, signInVisible: false, reloadsUsed: 0) == .healthy)
        #expect(PageStallPolicy.decide(path: "/web/conversations", renderedRows: 0, signInVisible: true, reloadsUsed: 0) == .healthy)
        #expect(PageStallPolicy.decide(path: "/web/authentication", renderedRows: 0, signInVisible: false, reloadsUsed: 0) == .healthy)
        #expect(PageStallPolicy.decide(path: "/signin/v2/identifier", renderedRows: 0, signInVisible: false, reloadsUsed: 0) == .healthy)
    }
}
