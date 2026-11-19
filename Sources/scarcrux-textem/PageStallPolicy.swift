import Foundation

// Decides what to do when the inbox page finished loading but Google's app
// never rendered any conversations.
//
// Why: after the 1.0b1 update relaunch (2026-11-19) the window stayed blank
// for 25 minutes. The page loaded (Textem's bridge ran once, seeing 0 rows)
// but the inbox never appeared, and the web process neither crashed nor
// failed a navigation, so neither existing recovery path fired. A plain
// relaunch loaded normally. The exact cause is not yet known; this recovers
// and records a content-free event so the next occurrence names itself.
enum PageStallPolicy {
    enum Action: Equatable { case healthy, reload, showError }

    static let grace: TimeInterval = 40

    /// - Parameters:
    ///   - path: the page's URL path when checked.
    ///   - renderedRows: most conversation rows the bridge has seen since this load.
    ///   - signInVisible: Google's sign-in form is on the page.
    ///   - reloadsUsed: stall reloads already done this session.
    static func decide(path: String, renderedRows: Int, signInVisible: Bool, reloadsUsed: Int) -> Action {
        // Only the inbox is expected to show rows. Sign-in, pairing and other
        // Google pages legitimately show none for as long as the person needs.
        guard path.hasPrefix("/web/conversations"), !signInVisible, renderedRows == 0 else { return .healthy }
        return reloadsUsed < 1 ? .reload : .showError
    }
}
