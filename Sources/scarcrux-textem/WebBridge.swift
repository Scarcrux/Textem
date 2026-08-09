import Foundation

// Injected JavaScript that reports Google Messages' unread state to native.
// Google doesn't expose the unread count in the document title (it's
// "Google Messages for web: Conversations"), so we read it from the DOM:
// conversation list items whose accessibility label marks them unread.
// aria-labels are more stable than Google's minified CSS class names.
//
// The `diag` payload carries alternate selector counts so the native side
// can log them and we can retune if Google changes their markup.
enum WebBridge {
    static let handlerName = "textem"

    static let userScript = """
    (function() {
      var HANDLER = 'textem';
      function post(obj) {
        try { window.webkit.messageHandlers[HANDLER].postMessage(obj); } catch (e) {}
      }
      function lower(s) { return (s || '').toLowerCase(); }

      function labelFor(el) {
        var label = lower(el.getAttribute('aria-label'));
        if (!label) {
          var inner = el.querySelector('[aria-label]');
          if (inner) label = lower(inner.getAttribute('aria-label'));
        }
        return label;
      }

      function countUnread() {
        var n = 0;
        var items = document.querySelectorAll('mws-conversation-list-item');
        items.forEach(function(el) {
          if (labelFor(el).indexOf('unread') !== -1) n++;
        });
        return n;
      }

      function diag() {
        var aria = 0;
        document.querySelectorAll('[aria-label]').forEach(function(e) {
          if (lower(e.getAttribute('aria-label')).indexOf('unread') !== -1) aria++;
        });
        return {
          mws: document.querySelectorAll('mws-conversation-list-item').length,
          aria: aria,
          unreadClass: document.querySelectorAll('.unread').length
        };
      }

      var lastCount = -1;
      var timer = null;
      function report(force) {
        var c = countUnread();
        if (c === lastCount && !force) return;
        lastCount = c;
        post({ type: 'unread', count: c, diag: diag() });
      }

      try {
        var obs = new MutationObserver(function() {
          clearTimeout(timer);
          timer = setTimeout(function() { report(false); }, 600);
        });
        obs.observe(document.documentElement, {
          childList: true, subtree: true,
          attributes: true, attributeFilter: ['aria-label', 'class']
        });
      } catch (e) {}

      setInterval(function() { report(true); }, 8000);
      setTimeout(function() { report(true); }, 1500);
    })();
    """
}
