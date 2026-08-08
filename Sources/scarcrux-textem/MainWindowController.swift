import AppKit

final class MainWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Textem"
        window.titlebarAppearsTransparent = false
        window.minSize = NSSize(width: 480, height: 480)
        window.center()
        // Persist window position/size across launches.
        window.setFrameAutosaveName("TextemMainWindow")

        let webController = WebViewController()
        window.contentViewController = webController

        self.init(window: window)
    }
}
