import AppKit

// While locked, the Messages page sits transparent under the App Lock cover so
// it keeps receiving messages (see LockedContentController). Clicks can't reach
// it, but keyboard focus could arrive through the key-view loop (Tab). Refuse
// focus for anything inside the locked page so nothing can be typed into it.
final class LockAwareWindow: NSWindow {
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if let view = responder as? NSView,
           let locked = contentViewController as? LockedContentController,
           view.isDescendant(of: locked.messagesView) {
            return false
        }
        return super.makeFirstResponder(responder)
    }
}
