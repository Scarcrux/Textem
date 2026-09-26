import AppKit

// Textem — native AppKit shell for Google Messages for web.

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
