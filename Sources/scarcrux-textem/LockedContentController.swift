import AppKit

// The locked window's content: the App Lock cover on top of the live Messages
// page, which stays in the window but hidden.
//
// Why not swap the page out of the window: WebKit suspends a web view that has
// no window, so Google Messages stopped receiving messages while Textem was
// locked and no (redacted) notification could ever fire. Owner test
// 2026-11-24: a text sent while locked was first seen one second after
// unlocking. A hidden view inside the window is the same state as a closed
// Textem window, which has always kept notifications working. Hidden views are
// also skipped by hit testing, VoiceOver and window snapshots, and the cover
// is opaque and on top.
final class LockedContentController: NSViewController {
    private let cover: NSViewController
    private let messages: NSView

    init(cover: NSViewController, keepingAlive messages: NSView, size: NSSize) {
        self.cover = cover
        self.messages = messages
        super.init(nibName: nil, bundle: nil)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        messages.removeFromSuperview()
        messages.isHidden = true
        messages.frame = container.bounds
        messages.autoresizingMask = [.width, .height]
        container.addSubview(messages)
        addChild(cover)
        cover.view.frame = container.bounds
        cover.view.autoresizingMask = [.width, .height]
        container.addSubview(cover.view, positioned: .above, relativeTo: messages)
        view = container
    }

    /// Hand the page back for display after unlocking.
    func releaseMessages() {
        messages.removeFromSuperview()
        messages.isHidden = false
    }

    var coverController: NSViewController { cover }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
