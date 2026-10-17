import Foundation

// Injected JavaScript reports complete conversation-row snapshots. Native code
// compares their fingerprints so a new message in an already-unread thread is
// observable even though the unread-conversation count does not change.
enum WebBridge {
    static let handlerName = "textem"

    static let userScript = """
    (function() {
      // Popup configurations inherit the opener's user-content controller.
      // Never let an account/sign-in popup impersonate the Messages page.
      if (window.opener) return;

      var HANDLER = 'textem';
      \(ConversationDOM.helpers)
      function post(obj) {
        try { window.webkit.messageHandlers[HANDLER].postMessage(obj); } catch (e) {}
      }
      function lower(s) { return (s || '').toLowerCase(); }
      function clean(s) { return (s || '').replace(/\\s+/g, ' ').trim(); }
      function normalized(s) {
        var value = clean(s);
        try { value = value.normalize('NFKC'); } catch (e) {}
        return value.toLocaleLowerCase();
      }
      var PHONE_ONLY_PREFIX = 'Use the Google Messages app on your phone to chat with ';

      function phoneOnlyConversation() {
        var text = document.body ? (document.body.innerText || '') : '';
        var lines = text.split(/\\r?\\n/);
        var prefix = normalized(PHONE_ONLY_PREFIX);
        for (var i = 0; i < lines.length; i++) {
          var line = clean(lines[i]);
          if (normalized(line).indexOf(prefix) === 0) {
            return clean(line.slice(PHONE_ONLY_PREFIX.length));
          }
        }
        return '';
      }

      function isUnread(el) {
        if (el.getAttribute('data-e2e-is-unread') === 'true') return true;
        if (el.querySelector('[data-e2e-is-unread="true"]')) return true;
        var al = el.getAttribute('aria-label') || '';
        if (!al) {
          var labelled = el.querySelector('[aria-label]');
          if (labelled) al = labelled.getAttribute('aria-label') || '';
        }
        return lower(al).indexOf('unread') !== -1;
      }

      function snapshot() {
        var items = document.querySelectorAll('mws-conversation-list-item');
        var rows = [];
        for (var i = 0; i < items.length; i++) {
          var el = items[i];
          var idLink = el.querySelector('a[href]');
          var id = textemConversationID(idLink);
          // Rows without a stable id cannot safely support notification actions.
          if (!id) continue;

          var snippetEl = el.querySelector('[data-e2e-conversation-snippet], mws-conversation-snippet');
          var snippet = snippetEl ? clean(snippetEl.textContent) : '';
          var nameEl = el.querySelector('[data-e2e-conversation-name], h3, .name');
          var sender = nameEl ? clean(nameEl.textContent) : '';
          if (!sender) {
            var label = el.getAttribute('aria-label') || '';
            sender = clean(label.replace(/unread.*/i, '').replace(/[,.].*$/, ''));
          }

          // Do not include relative timestamps or unread styling: those change
          // without a new message and would create false notifications.
          rows.push({
            id: id,
            sender: sender,
            snippet: snippet,
            fingerprint: sender + '|' + snippet,
            unread: isUnread(el)
          });
        }
        return rows;
      }

      var lastSerialized = null;
      var lastPhoneOnlySerialized = null;
      var timer = null;

      function reportPhoneOnly(force) {
        var selected = document.querySelector(
          'mws-conversation-list-item a[aria-selected="true"], ' +
          'mws-conversation-list-item [aria-selected="true"][href]');
        // Google's row label can append sender metadata inside the same text
        // node. Read the active pane's notice instead; native matching accepts
        // an expansion only when it resolves to one stored conversation.
        var conversation = phoneOnlyConversation();
        var visible = !!selected && !!conversation;
        var conversationID = textemConversationID(selected);
        if (!conversationID && selected) {
          var row = selected.closest('mws-conversation-list-item');
          var route = row ? row.querySelector('a[href]') : null;
          conversationID = textemConversationID(route);
        }
        var serialized = JSON.stringify({
          visible: visible, conversation: conversation, conversationID: conversationID
        });
        if (!force && serialized === lastPhoneOnlySerialized) return;
        lastPhoneOnlySerialized = serialized;
        post({
          type: 'phoneOnlyState', visible: visible,
          conversation: conversation, conversationID: conversationID
        });
      }

      function report(force) {
        var rows = snapshot();
        var serialized = JSON.stringify(rows);
        if (force || serialized !== lastSerialized) {
          lastSerialized = serialized;
          var unread = 0;
          for (var i = 0; i < rows.length; i++) if (rows[i].unread) unread++;
          post({ type: 'snapshot', count: unread, rows: rows,
            domRows: document.querySelectorAll('mws-conversation-list-item').length });
        }
        reportPhoneOnly(force);
      }

      try {
        var obs = new MutationObserver(function() {
          clearTimeout(timer);
          timer = setTimeout(function() { report(false); }, 250);
        });
        obs.observe(document.documentElement, {
          childList: true,
          subtree: true,
          characterData: true,
          attributes: true,
          attributeFilter: ['aria-label', 'aria-selected', 'data-e2e-is-unread', 'data-e2e-conversation', 'href']
        });
      } catch (e) {}

      // The periodic report heals missed or implementation-specific DOM changes;
      // native fingerprinting makes duplicate reports harmless.
      setInterval(function() { report(true); }, 8000);
      setTimeout(function() { report(true); }, 500);
    })();
    """
}
