import Foundation

// data-e2e-conversation is a test marker in current Google builds, not a
// guaranteed ID value. The row's same-origin navigation route owns its ID.
enum ConversationDOM {
    static let helpers = #"""
    function textemConversationID(link) {
      if (!link || !link.getAttribute('href')) return '';
      try {
        var url = new URL(link.getAttribute('href'), location.href);
        if (url.origin !== location.origin || url.search || url.hash) return '';
        var match = url.pathname.match(/^\/web\/conversations\/([^/]+)\/?$/);
        if (!match) return '';
        var id = decodeURIComponent(match[1]);
        return id && id.length <= 512 && !/[\/\s?#]/.test(id) ? id : '';
      } catch (_) { return ''; }
    }
    """#
}
