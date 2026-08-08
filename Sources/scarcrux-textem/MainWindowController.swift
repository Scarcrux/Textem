import AppKit

final class MainWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Textem"
        window.titlebarAppearsTransparent = false
        // Keep the window above Google Messages' responsive breakpoint so it
        // doesn't collapse from the two-column (list + thread) layout down to
        // a single column.
        window.minSize = NSSize(width: 920, height: 560)
        window.center()
        // Persist window position/size across launches.
        window.setFrameAutosaveName("TextemMainWindow")

        let webController = WebViewController()
        window.contentViewController = webController

        self.init(window: window)
    }
}
