import AppKit
import SwiftUI

// Hosts the first-run OnboardingView in a modal-ish panel.
@MainActor
final class OnboardingWindowController: NSWindowController {
    convenience init(onDone: @escaping () -> Void) {
        var controller: OnboardingWindowController?
        let view = OnboardingView(onDone: {
            onDone()
            controller?.close()
        })
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Textem"
        window.styleMask = [.titled]
        window.isReleasedWhenClosed = false
        self.init(window: window)
        controller = self
    }
}
