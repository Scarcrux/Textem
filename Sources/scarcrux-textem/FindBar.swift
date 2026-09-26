import AppKit

// A slim find bar that overlays the top of the web view (⌘F). Reports search
// requests and close via closures; the controller drives WKWebView.find.
@MainActor
final class FindBar: NSView {
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
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        field.placeholderString = "Find on page"
        field.target = self
        field.action = #selector(searchAction)
        field.sendsSearchStringImmediately = false

        let prev = button("‹", accessibilityLabel: "Previous match", #selector(prevAction))
        let next = button("›", accessibilityLabel: "Next match", #selector(nextAction))
        let done = NSButton(title: "Done", target: self, action: #selector(closeAction))
        done.bezelStyle = .rounded

        let stack = NSStackView(views: [field, prev, next, done])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
    }

    private func button(_ title: String, accessibilityLabel: String,
                        _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.setAccessibilityLabel(accessibilityLabel)
        return b
    }

    @objc private func searchAction() { onFind?(field.stringValue, false) }
    @objc private func nextAction() { onFind?(field.stringValue, false) }
    @objc private func prevAction() { onFind?(field.stringValue, true) }
    @objc private func closeAction() { onClose?() }
}
