import AppKit

// A slim find bar that overlays the top of the web view (⌘F). Reports search
// requests and close via closures; the controller drives WKWebView.find.
@MainActor
final class FindBar: NSView, NSSearchFieldDelegate {
    var onFind: ((String, Bool) -> Void)?
    var onClose: (() -> Void)?

    private let field = NSSearchField()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var query: String { field.stringValue }

    func focus() {
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    private func build() {
        // Toolbar-style material instead of a flat fill: it follows light/dark
        // switches on its own (a CGColor assigned once does not) and reads as
        // window chrome rather than as part of Google's page.
        let material = NSVisualEffectView()
        material.material = .titlebar
        material.blendingMode = .withinWindow
        material.state = .followsWindowActiveState
        let hairline = NSBox()
        hairline.boxType = .separator

        field.placeholderString = "Find on page"
        field.target = self
        field.action = #selector(searchAction)
        field.delegate = self
        field.sendsSearchStringImmediately = false
        field.controlSize = .large

        let previous = button("chevron.left", accessibilityLabel: "Previous match", #selector(prevAction))
        let next = button("chevron.right", accessibilityLabel: "Next match", #selector(nextAction))
        previous.toolTip = "Previous match (⇧⌘G)"
        next.toolTip = "Next match (⌘G)"
        let done = NSButton(title: "Done", target: self, action: #selector(closeAction))
        done.bezelStyle = .rounded
        done.controlSize = .large

        let stack = NSStackView(views: [field, previous, next, done])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.setCustomSpacing(10, after: next)
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 8, right: 12)

        for view in [material, stack, hairline] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            material.leadingAnchor.constraint(equalTo: leadingAnchor),
            material.trailingAnchor.constraint(equalTo: trailingAnchor),
            material.topAnchor.constraint(equalTo: topAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
    }

    private func button(_ symbol: String, accessibilityLabel: String,
                        _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityLabel) ?? NSImage()
        let b = NSButton(image: image, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .large
        b.setAccessibilityLabel(accessibilityLabel)
        return b
    }

    // Escape closes the bar, as in Safari. Without this NSSearchField swallows
    // Escape to clear its text and the bar can only be dismissed with the mouse.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        onClose?()
        return true
    }

    @objc private func searchAction() { onFind?(field.stringValue, false) }
    @objc private func nextAction() { onFind?(field.stringValue, false) }
    @objc private func prevAction() { onFind?(field.stringValue, true) }
    @objc private func closeAction() { onClose?() }
}
