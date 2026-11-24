import AppKit
import SwiftUI

// Hosts the first-run OnboardingView. The window can be closed (close button
// or ⌘W) as well as finished with Sign In; either way counts as having seen
// the guide, and Help > Sign-in Help reopens it.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private var onDone: (() -> Void)?

    convenience init(onDone: @escaping () -> Void) {
        var controller: OnboardingWindowController?
        let view = OnboardingView(onDone: { controller?.close() })
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Textem"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        self.init(window: window)
        self.onDone = onDone
        window.delegate = self
        controller = self
    }

    /// Close without counting the guide as seen (used when Textem locks, so
    /// the guide comes back after unlocking).
    func dismissForLock() {
        onDone = nil
        close()
    }

    func windowWillClose(_ notification: Notification) {
        let finish = onDone
        onDone = nil
        finish?()
    }
}
