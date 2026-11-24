import AppKit
import Foundation

struct ConversationCodePrompt: Equatable {
    let url: URL
    let code: String
    let receivedAt: Date?
    private let text: String
    private let messageIndex: Int

    init?(payload: [String: Any], currentURL: URL?) {
        guard let currentURL, WebNavigationPolicy.isAllowedBridgeOrigin(
            scheme: currentURL.scheme ?? "", host: currentURL.host ?? ""),
            currentURL.pathComponents.count == 4,
            currentURL.pathComponents[1...2].elementsEqual(["web", "conversations"]),
            currentURL.query == nil, currentURL.fragment == nil,
            payload["url"] as? String == currentURL.absoluteString,
            let messages = payload["messages"] as? [[String: Any]], messages.count <= 12 else { return nil }
        for item in messages {
            guard let text = item["text"] as? String, text.utf8.count <= 4_096,
                  let index = item["index"] as? Int, (0..<1_000_000).contains(index),
                  let code = WebViewController.firstCode(in: [text]) else { continue }
            url = currentURL
            self.code = code
            self.text = text
            messageIndex = index
            let milliseconds = (item["timeMS"] as? NSNumber)?.doubleValue ?? 0
            receivedAt = milliseconds.isFinite && milliseconds > 0
                ? Date(timeIntervalSince1970: milliseconds / 1000) : nil
            return
        }
        return nil
    }

    func title(at now: Date = .now) -> String {
        guard let receivedAt, receivedAt <= now else { return "Verification code · Message time unavailable" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Verification code · " + formatter.localizedString(for: receivedAt, relativeTo: now)
    }

    var revealScript: String? {
        guard let url = ReplyAutomation.jsonString(url.absoluteString),
              let text = ReplyAutomation.jsonString(text) else { return nil }
        return """
        (function(expectedURL, expectedIndex, expectedText) {
          \(ConversationDOM.helpers)
          \(Self.reader)
          var context = textemCodeContext();
          if (context.url !== expectedURL || !context.messages.some(function(item) {
            return item.index === expectedIndex && item.text === expectedText;
          })) return false;
          var message = document.querySelectorAll('mws-message-wrapper')[expectedIndex];
          message.scrollIntoView({block:'center'});
          if (typeof message.animate === 'function') {
            message.animate([{outline:'2px solid #3278d1'}, {outline:'2px solid transparent'}],
                            {duration:1800, easing:'ease-in'});
          }
          return true;
        })(\(url), \(messageIndex), \(text))
        """
    }

    // Scoped to the rendered, selected conversation. The inbox snippets and
    // outgoing messages never supply this prompt.
    static let reader = #"""
    function textemCodeContext() {
      var empty = { url: location.href, messages: [] };
      var selected = document.querySelectorAll('mws-conversation-list-item a[aria-selected="true"]');
      var page = document.createElement('a');
      page.href = location.href;
      var current = textemConversationID(page);
      if (selected.length !== 1 || !current || textemConversationID(selected[0]) !== current) return empty;

      var messages = document.querySelectorAll('mws-message-wrapper');
      var entries = [];
      for (var i = messages.length - 1; i >= Math.max(0, messages.length - 12); i--) {
        var message = messages[i];
        if (!message.getClientRects().length || getComputedStyle(message).visibility !== 'visible' || message.closest('[hidden], [aria-hidden="true"]') ||
            message.matches('[is-outgoing="true"], [data-e2e-message-outgoing="true"]') ||
            message.querySelector('[data-e2e-message-outgoing="true"], [is-outgoing="true"]')) continue;
        var parts = message.querySelectorAll('mws-text-message-part');
        var text = Array.from(parts, function(part) { return part.textContent || ''; }).join('\n').trim();
        if (text.length <= 2048 && /[0-9]{4}/.test(text)) {
          var stamp = message.querySelector('time[datetime]');
          var value = stamp ? stamp.getAttribute('datetime') : '';
          var timeMS = /^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:?\d{2})$/.test(value) ? Date.parse(value) : 0;
          if (!timeMS) {
            var numeric = message.getAttribute('data-timestamp') || '';
            if (/^\d{13}$/.test(numeric)) timeMS = Number(numeric);
            else if (/^\d{10}$/.test(numeric)) timeMS = Number(numeric) * 1000;
          }
          entries.push({text:text, index:i, timeMS:timeMS || 0});
        }
      }
      return { url: location.href, messages: entries };
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
    let showButton = NSButton(title: "Show Message", target: nil, action: nil)
    let dismissButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)!,
                                 target: nil, action: nil)
    private let prompt = NSTextField(labelWithString: "Verification code")
    private var copied = false

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
        showButton.bezelStyle = .rounded
        dismissButton.bezelStyle = .rounded
        dismissButton.setAccessibilityLabel("Dismiss verification code prompt")
        dismissButton.toolTip = "Dismiss"
        addArrangedSubview(prompt)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addArrangedSubview(spacer)
        addArrangedSubview(showButton)
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
        copied = true
        prompt.stringValue = "Verification code copied"
        copyButton.title = "Copy Again"
    }

    func update(title: String, reset: Bool) {
        if reset {
            copied = false
            copyButton.title = "Copy Code"
        }
        if !copied { prompt.stringValue = title }
    }
}
