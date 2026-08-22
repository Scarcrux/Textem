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

      // Best-effort sender + snippet of the newest unread conversation, for
      // rich notifications. Selectors are heuristic (Google's DOM is minified).
      function latestUnread() {
        var items = document.querySelectorAll('mws-conversation-list-item');
        for (var i = 0; i < items.length; i++) {
          if (!isUnread(items[i])) continue;
          var el = items[i];
          var snip = '';
          var snipEl = el.querySelector('mws-conversation-snippet');
          if (snipEl) snip = (snipEl.textContent || '').trim();
          var name = '';
          var nameEl = el.querySelector('h3, .name, [data-e2e-conversation-name]');
          if (nameEl) name = (nameEl.textContent || '').trim();
          if (!name) {
            var al = el.getAttribute('aria-label') || '';
            name = al.replace(/unread.*/i, '').replace(/[,.].*$/, '').trim();
          }
          return { sender: name, snippet: snip };
        }
        return null;
      }

      var lastCount = -1;
      var timer = null;
      function report(force) {
        var c = countUnread();
        if (c === lastCount && !force) return;
        lastCount = c;
        var msg = { type: 'unread', count: c };
        var latest = latestUnread();
        if (latest) { msg.sender = latest.sender; msg.snippet = latest.snippet; }
        post(msg);
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
