import AppKit

// The locked window's content: the App Lock cover on top of the live Messages
// page. The page stays visible to WebKit but fully transparent, under an
// opaque cover that alone receives clicks and accessibility.
//
// Why (evidence, 2026-11-24):
// - 1.0b5 swapped the page out of the window. The owner's live test: a text
//   sent while locked was first seen one second after unlocking.
// - 1.0b6 candidate kept the page in the window but isHidden. Same result
//   (text first seen at unlock, 20:59:57).
// - Standalone WKWebView probe (/tmp/wkprobe, criteria written first):
//   requestAnimationFrame callbacks per 30 s were 1,868 covered, 1,928 at
//   alpha 0 under a cover, 0 when isHidden, 0 with the window ordered out.
//   Timers kept running when hidden, so the page wasn't frozen; it stopped
//   rendering, and Google Messages only adds new messages to the DOM when it
//   renders. Alpha 0 under an opaque cover keeps rendering.
final class LockedContentController: NSViewController {
    private let cover: NSViewController
    private let messages: NSView

    init(cover: NSViewController, keepingAlive messages: NSView, size: NSSize) {
        self.cover = cover
        self.messages = messages
        super.init(nibName: nil, bundle: nil)
        let container = CoverOnlyView(frame: NSRect(origin: .zero, size: size))
        messages.removeFromSuperview()
        messages.isHidden = false
        messages.alphaValue = 0
        messages.frame = container.bounds
        messages.autoresizingMask = [.width, .height]
        container.addSubview(messages)
        addChild(cover)
        cover.view.frame = container.bounds
        cover.view.autoresizingMask = [.width, .height]
        container.addSubview(cover.view, positioned: .above, relativeTo: messages)
        container.cover = cover.view
        view = container
    }

    /// Hand the page back for display after unlocking.
    func releaseMessages() {
        messages.removeFromSuperview()
        messages.alphaValue = 1
    }

    var coverController: NSViewController { cover }
    var messagesView: NSView { messages }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Routes clicks and accessibility only to the cover, so the transparent page
/// underneath can't be clicked or read by VoiceOver.
final class CoverOnlyView: NSView {
    weak var cover: NSView?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let cover else { return nil }
        return cover.hitTest(convert(point, to: cover.superview))
    }

    override func accessibilityChildren() -> [Any]? {
        cover.map { [$0] } ?? []
    }
}
