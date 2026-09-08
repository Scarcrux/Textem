import AppKit

// Shown when the web client fails to load and the automatic retries are spent.
//
// Why this exists: WKWebView renders a FAILED navigation as a blank white page
// and surfaces nothing on its own. Without a failure path, one transient fault
// (offline at login, sleep/wake, a DNS blip) strands the user on a white window
// forever, with no explanation and no way back. This view replaces that dead end
// with a stated cause and a Retry.
final class LoadErrorView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Can’t reach Google Messages")

    private let detailLabel = NSTextField(labelWithString: "")
    var onRetry: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.alignment = .center

        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 4

        let button = NSButton(title: "Retry", target: self, action: #selector(retryTapped))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"

        let stack = NSStackView(views: [titleLabel, detailLabel, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Self-describing: the message states the actual underlying cause.
    // Shown from the FIRST failure (as "Reconnecting…") rather than only after
    // retries are spent — otherwise the user stares at an unexplained blank
    // window for the whole backoff ladder, which is the very complaint this
    // view exists to fix.
    func present(message: String, isRetrying: Bool) {
        titleLabel.stringValue = isRetrying ? "Reconnecting…" : "Can’t reach Google Messages"
        detailLabel.stringValue = message
        isHidden = false
    }

    @objc private func retryTapped() { onRetry?() }
}
