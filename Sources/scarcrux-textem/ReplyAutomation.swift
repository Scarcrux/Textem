import Foundation

// The script that performs a notification's inline reply inside the Google
// Messages web client.
//
// Why it is its own type: it used to be an inline string in WebViewController,
// so the only way to exercise it was a live inbound message. As a pure builder,
// the EXACT script the app injects can run against a fixture page in WebKit
// tests (ReplyAutomationWebKitTests). That proves the script's own logic —
// targeting, fail-closed ordering, outcome reporting — but NOT that Google's
// live markup still matches the selectors below; that half still needs a real
// end-to-end message.
//
// Contract (relied on by WebViewController and the tests): the script posts
// exactly one `{type: "replyResult", requestId, ok, unknown?, reason?}` to the
// named message handler. `unknown: true` means Send was pressed but the outcome
// could not be confirmed, so the user must check before resending.
enum ReplyAutomation {
    struct Timeouts: Sendable {
        var selectMilliseconds: Int
        var sendMilliseconds: Int
        var confirmMilliseconds: Int

        // 10s to land on the thread and find the composer, 4s for the text to
        // stick and Send to enable, 5s for the composer to clear after Send.
        // WebViewController's 22s watchdog sits above their 19s sum.
        static let production = Timeouts(
            selectMilliseconds: 10_000, sendMilliseconds: 4_000, confirmMilliseconds: 5_000)
    }

    static func script(requestID: String, text: String, conversationID: String,
                       handlerName: String = WebBridge.handlerName,
                       timeouts: Timeouts = .production) -> String? {
        guard let requestJSON = jsonString(requestID),
              let textJSON = jsonString(text),
              let idJSON = jsonString(conversationID),
              let handlerJSON = jsonString(handlerName) else { return nil }

        // Fail closed: after clicking the row, wait until location exactly
        // matches that row's href before querying a composer. Querying
        // immediately could type into the previously open thread.
        return """
        (function(requestId, reply, convId) {
          function post(o) {
            o.type = 'replyResult'; o.requestId = requestId;
            try { window.webkit.messageHandlers[\(handlerJSON)].postMessage(o); } catch(e) {}
          }
          function fail(reason) { post({ ok: false, unknown: false, reason: reason }); }
          function route(url) {
            var u = new URL(url, location.href);
            return u.origin + u.pathname + u.search + u.hash;
          }
          function valueOf(box) {
            return ('value' in box) ? box.value : (box.textContent || '');
          }

          var links = document.querySelectorAll('a[data-e2e-conversation]');
          var link = null;
          for (var i = 0; i < links.length; i++) {
            if (links[i].getAttribute('data-e2e-conversation') === convId) { link = links[i]; break; }
          }
          if (!link || !link.href) { fail('conversation-not-found'); return; }
          var targetRoute = route(link.href);
          if (route(location.href) !== targetRoute) link.click();

          var started = Date.now();
          (function waitForTarget() {
            if (route(location.href) !== targetRoute) {
              if (Date.now() - started > \(timeouts.selectMilliseconds)) { fail('conversation-not-selected'); return; }
              setTimeout(waitForTarget, 100); return;
            }

            var box = document.querySelector(
              'textarea[data-e2e-message-input-box], mws-message-compose textarea, mws-message-compose [contenteditable="true"]');
            if (!box) {
              if (Date.now() - started > \(timeouts.selectMilliseconds)) { fail('composer-not-found'); return; }
              setTimeout(waitForTarget, 100); return;
            }

            box.focus();
            if ('value' in box) {
              var proto = box instanceof HTMLTextAreaElement
                ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
              var descriptor = Object.getOwnPropertyDescriptor(proto, 'value');
              if (!descriptor || !descriptor.set) { fail('composer-unsupported'); return; }
              descriptor.set.call(box, reply);
            } else {
              box.textContent = reply;
            }
            box.dispatchEvent(new InputEvent('input', {
              bubbles: true, inputType: 'insertText', data: reply
            }));

            var sendStarted = Date.now();
            (function waitForSend() {
              if (route(location.href) !== targetRoute) { fail('conversation-changed'); return; }
              if (valueOf(box) !== reply) {
                if (Date.now() - sendStarted > \(timeouts.sendMilliseconds)) { fail('composer-rejected-text'); return; }
                setTimeout(waitForSend, 100); return;
              }
              var compose = box.closest('mws-message-compose');
              var send = compose ? compose.querySelector('[data-e2e-send-button], button[aria-label="Send"]') : null;
              if (!send) send = document.querySelector('[data-e2e-send-button]');
              if (!send || send.disabled) {
                if (Date.now() - sendStarted > \(timeouts.sendMilliseconds)) { fail('send-button-unavailable'); return; }
                setTimeout(waitForSend, 100); return;
              }
              send.click();

              var confirmStarted = Date.now();
              (function confirmSubmission() {
                if (valueOf(box) === '') { post({ ok: true }); return; }
                if (Date.now() - confirmStarted > \(timeouts.confirmMilliseconds)) {
                  post({ ok: false, unknown: true, reason: 'submission-unconfirmed' });
                  return;
                }
                setTimeout(confirmSubmission, 100);
              })();
            })();
          })();
        })(\(requestJSON), \(textJSON), \(idJSON));
        """
    }

    static func jsonString(_ value: String) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
