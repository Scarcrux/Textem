import AppKit
import SwiftUI

// Hosts the SwiftUI SettingsView in a small titled window (⌘, ).
@MainActor
final class SettingsWindowController: NSWindowController {
    convenience init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Textem Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }
}
