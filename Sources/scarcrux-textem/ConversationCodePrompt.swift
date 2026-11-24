import AppKit
import Foundation

struct ConversationCodePrompt: Equatable {
    let url: URL
    let code: String

    init?(payload: [String: Any], currentURL: URL?) {
        guard let currentURL, WebNavigationPolicy.isAllowedBridgeOrigin(
            scheme: currentURL.scheme ?? "", host: currentURL.host ?? ""),
            currentURL.pathComponents.count == 4,
            currentURL.pathComponents[1...2].elementsEqual(["web", "conversations"]),
            currentURL.query == nil, currentURL.fragment == nil,
            payload["url"] as? String == currentURL.absoluteString,
            let texts = payload["texts"] as? [String], texts.count <= 12,
            let code = WebViewController.firstCode(in: texts.filter { $0.utf8.count <= 4_096 }) else { return nil }
        url = currentURL
        self.code = code
    }

    // Scoped to the rendered, selected conversation. The inbox snippets and
    // outgoing messages never supply this prompt.
    static let reader = #"""
    function textemCodeContext() {
      var empty = { url: location.href, texts: [] };
      var selected = document.querySelectorAll('mws-conversation-list-item a[aria-selected="true"]');
      var page = document.createElement('a');
      page.href = location.href;
      var current = textemConversationID(page);
      if (selected.length !== 1 || !current || textemConversationID(selected[0]) !== current) return empty;

      var messages = document.querySelectorAll('mws-message-wrapper');
      var texts = [];
      for (var i = messages.length - 1; i >= Math.max(0, messages.length - 12); i--) {
        var message = messages[i];
        if (!message.getClientRects().length || getComputedStyle(message).visibility !== 'visible' || message.closest('[hidden], [aria-hidden="true"]') ||
            message.matches('[is-outgoing="true"], [data-e2e-message-outgoing="true"]') ||
            message.querySelector('[data-e2e-message-outgoing="true"], [is-outgoing="true"]')) continue;
        var parts = message.querySelectorAll('mws-text-message-part');
        var text = Array.from(parts, function(part) { return part.textContent || ''; }).join('\n').trim();
        if (text.length <= 2048 && /[0-9]{4}/.test(text)) texts.push(text);
      }
      return { url: location.href, texts: texts };
    }
    """#

    static let readScript = """
    (function() {
      \(ConversationDOM.helpers)
      \(reader)
      return textemCodeContext();
    })()
    """
}

@MainActor
final class ConversationCodeBar: NSStackView {
    let copyButton = NSButton(title: "Copy Code", target: nil, action: nil)
    let dismissButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)!,
                                 target: nil, action: nil)
    private let prompt = NSTextField(labelWithString: "Verification code in this conversation")

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Verification code")
        prompt.lineBreakMode = .byTruncatingTail
        prompt.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        copyButton.bezelStyle = .rounded
        dismissButton.bezelStyle = .rounded
        dismissButton.setAccessibilityLabel("Dismiss verification code prompt")
        dismissButton.toolTip = "Dismiss"
        addArrangedSubview(prompt)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addArrangedSubview(spacer)
        addArrangedSubview(copyButton)
        addArrangedSubview(dismissButton)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showCopied() {
        prompt.stringValue = "Verification code copied"
        copyButton.title = "Copy Again"
    }

    func reset() {
        prompt.stringValue = "Verification code in this conversation"
        copyButton.title = "Copy Code"
    }
}
