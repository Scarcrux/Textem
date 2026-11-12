import AppKit

// Shown when the web client fails to load and the automatic retries are spent.
//
// Why this exists: WKWebView renders a FAILED navigation as a blank white page
// and surfaces nothing on its own. Without a failure path, one transient fault
// (offline at login, sleep/wake, a DNS blip) strands the user on a white window
// forever, with no explanation and no way back. This view replaces that dead end
// with a stated cause and a Retry.
final class LoadErrorView: NSView {
    private let iconView = NSImageView()
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "Can’t reach Google Messages")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton(title: "Try Again", target: nil, action: nil)
    var onRetry: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        iconView.image = NSImage(systemSymbolName: "wifi.exclamationmark",
                                 accessibilityDescription: nil)
        iconView.symbolConfiguration = .init(pointSize: 40, weight: .regular)
        iconView.contentTintColor = .tertiaryLabelColor

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.alignment = .center

        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.isSelectable = false
        detailLabel.maximumNumberOfLines = 4

        retryButton.target = self
        retryButton.action = #selector(retryTapped)
        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .large
        retryButton.keyEquivalent = "\r"

        let stack = NSStackView(views: [iconView, spinner, titleLabel, detailLabel, retryButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(14, after: iconView)
        stack.setCustomSpacing(14, after: spinner)
        stack.setCustomSpacing(18, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The background is drawn here, not assigned once as a CGColor: a CGColor is
    // resolved against the appearance in force at that moment and never again, so
    // a view created in dark mode kept its dark fill after the system switched to
    // light (dark-on-dark text). AppKit calls this again on appearance changes.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    // Self-describing: the message states the actual underlying cause.
    // Shown from the FIRST failure (as "Reconnecting…") rather than only after
    // retries are spent — otherwise the user stares at an unexplained blank
    // window for the whole backoff ladder, which is the very complaint this
    // view exists to fix.
    func present(message: String, isRetrying: Bool) {
        titleLabel.stringValue = isRetrying ? "Reconnecting…" : "Can’t reach Google Messages"
        detailLabel.stringValue = message
        // One state indicator at a time: a spinner while Textem is still trying
        // on its own, the offline glyph once it has stopped and needs the user.
        iconView.isHidden = isRetrying
        spinner.isHidden = !isRetrying
        if isRetrying { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        retryButton.title = isRetrying ? "Retry Now" : "Try Again"
        isHidden = false
    }

    @objc private func retryTapped() { onRetry?() }
}
