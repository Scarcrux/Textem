import AppKit
import WebKit

// Route the user's notification reply through our own window's native input
// path. Google's Send handler rejects JavaScript-generated clicks
// (event.isTrusted == false). No global mouse/cursor or Accessibility access.
@MainActor
enum NativeWebClick {
    static func send(in webView: WKWebView, target: [String: Any]) -> Bool {
        func number(_ key: String) -> Double? {
            guard let value = (target[key] as? NSNumber)?.doubleValue, value.isFinite else { return nil }
            return value
        }
        guard let x = number("x"), let y = number("y"),
              let width = number("viewportWidth"), let height = number("viewportHeight"),
              width > 0, height > 0, x >= 0, y >= 0, x < width, y < height,
              let window = webView.window else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !window.isVisible { window.orderBack(nil) }
        webView.layoutSubtreeIfNeeded()
        let inset = webView.safeAreaInsets
        let bounds = webView.bounds
        let contentWidth = bounds.width - inset.left - inset.right
        let contentHeight = bounds.height - inset.top - inset.bottom
        guard contentWidth > 0, contentHeight > 0 else { return false }
        let nativeX = bounds.minX + inset.left + CGFloat(x / width) * contentWidth
        let fromTop = inset.top + CGFloat(y / height) * contentHeight
        let nativeY = webView.isFlipped ? bounds.minY + fromTop : bounds.maxY - fromTop
        let point = webView.convert(NSPoint(x: nativeX, y: nativeY), to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: time,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time + 0.01,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1,
            clickCount: 1, pressure: 0) else { return false }
        let localPoint = NSPoint(x: nativeX, y: nativeY)
        guard let hit = webView.hitTest(webView.convert(localPoint, to: webView.superview)),
              hit === webView || hit.isDescendant(of: webView) else { return false }
        hit.mouseDown(with: down)
        hit.mouseUp(with: up)
        return true
    }
}
