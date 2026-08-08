import AppKit

// Textem — Phase 0 auth spike.
// Native AppKit shell hosting Google Messages for web in a WKWebView.
// Goal of this phase: pair an account (QR *or* the new Google-account
// sign-in) and learn whether Google blocks account sign-in inside a
// WKWebView. Everything else (notifications, badge, tray) comes later.

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
