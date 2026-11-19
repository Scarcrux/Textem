import AppKit

// Textem — a macOS wrapper for Google Messages for web.

// Before anything touches WebKit or preferences.
LegacyIdentityMigration.runIfNeeded()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
