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

      // The conversation list lives in the light DOM as
      // <mws-conversation-list-item> (no shadow roots). Google flags an
      // unread conversation with data-e2e-is-unread="true" — an automation
      // hook that's more stable than its minified CSS classes. Fall back to
      // an aria-label mention of "unread" if that attribute ever disappears.
      function isUnread(el) {
        if (el.getAttribute('data-e2e-is-unread') === 'true') return true;
        if (el.querySelector('[data-e2e-is-unread="true"]')) return true;
        var al = el.getAttribute('aria-label') || '';
        if (!al) { var a = el.querySelector('[aria-label]'); if (a) al = a.getAttribute('aria-label') || ''; }
        return lower(al).indexOf('unread') !== -1;
      }

      function countUnread() {
        var items = document.querySelectorAll('mws-conversation-list-item');
        var n = 0;
        for (var i = 0; i < items.length; i++) {
          if (isUnread(items[i])) n++;
        }
        return n;
      }

      var lastCount = -1;
      var timer = null;
      function report(force) {
        var c = countUnread();
        if (c === lastCount && !force) return;
        lastCount = c;
        post({ type: 'unread', count: c });
      }

      try {
        var obs = new MutationObserver(function() {
          clearTimeout(timer);
          timer = setTimeout(function() { report(false); }, 1000);
        });
        obs.observe(document.documentElement, {
          childList: true, subtree: true,
          attributes: true, attributeFilter: ['aria-label']
        });
      } catch (e) {}

      setInterval(function() { report(true); }, 8000);
      setTimeout(function() { report(true); }, 2000);
    })();
    """
}
