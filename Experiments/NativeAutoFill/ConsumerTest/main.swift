import AppKit
import Darwin
import WebKit

@MainActor final class Consumer: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    private var window: NSWindow!
    private var web: WKWebView!
    private var bad = false, good = false, live = false
    private let output: URL
    private let runID = UUID().uuidString
    init(output: URL) { self.output = output; super.init() }
    private func record(_ event: String, _ counts: [String: Int] = [:]) {
        let fd = open(output.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size < 65536 else { return }
        let value: [String: Any] = ["event": event, "at": ISO8601DateFormatter().string(from: Date()), "counts": counts,
                                  "process": Int(ProcessInfo.processInfo.processIdentifier), "run": runID]
        guard var bytes = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys) else { return }
        bytes.append(10); bytes.withUnsafeBytes { storage in _ = write(fd, storage.baseAddress, storage.count) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let content = WKUserContentController(); content.add(self, name: "field")
        let config = WKWebViewConfiguration(); config.userContentController = content; config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 480), configuration: config)
        web.navigationDelegate = self
        window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Textem AutoFill Consumer Test — local field"
        window.contentView = web; window.center(); window.makeKeyAndOrderFront(nil)
        let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item)
        let appMenu = NSMenu(); item.submenu = appMenu
        appMenu.addItem(withTitle: "Quit consumer test", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApplication.shared.mainMenu = menu; NSApplication.shared.activate(ignoringOtherApps: true)
        record("consumer_started")
        web.loadHTMLString(Self.html, baseURL: URL(string: "https://example.com/"))
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === web, message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any], Set(body.keys) == ["phase", "match", "length", "trusted", "bounds", "type"],
              let phase = body["phase"] as? String, let match = body["match"] as? Bool,
              let length = body["length"] as? Int, (0...6).contains(length),
              let trusted = body["trusted"] as? Bool, let bounds = body["bounds"] as? Bool,
              let type = body["type"] as? String else { record("observer_refused"); return }
        let origin = message.frameInfo.securityOrigin.host == "example.com"
        if phase == "CONTROL_BAD", !trusted, !match, length == 6 { bad = true; record("control_bad_refused"); return }
        if phase == "CONTROL_GOOD", !trusted, match, length == 6 { good = true; record("control_good_detected"); return }
        if phase == "LIVE", type == "ready" {
            live = bad && good && !match && length == 0 && origin && bounds
            record(live ? "ready_empty_controlled_field" : "consumer_design_refused", ["origin": origin ? 1 : 0, "bounds": bounds ? 1 : 0,
                "bad_control": bad ? 1 : 0, "good_control": good ? 1 : 0, "empty": length == 0 ? 1 : 0])
            return
        }
        guard phase == "LIVE", live, origin else { record("live_observation_refused"); return }
        record(match ? "live_field_matches_dummy" : "live_field_does_not_match", ["length": length, "trusted_event": trusted ? 1 : 0])
        // Observation only. No completeOneTimeCodeRequest, testCompletion,
        // clipboard, Keychain or live field value assignment in this consumer.
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        decisionHandler(action.navigationType == .other && (url?.absoluteString == "about:blank" || url?.absoluteString == "https://example.com/") ? .allow : .cancel)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    static let html = #"""
    <!doctype html><meta name="viewport" content="width=device-width, initial-scale=1"><meta charset="utf-8">
    <style>body{margin:0;padding:36px;background:#f5f7fb;color:#17243a;font:17px system-ui}h1{font-size:24px}p{line-height:1.5}input{font:30px system-ui;letter-spacing:8px;width:270px;padding:14px;border:2px solid #3478eb;border-radius:10px;background:white}small{display:block;margin-top:28px;line-height:1.5;color:#526077}</style>
    <h1>Native code AutoFill — controlled test</h1>
    <p>Use macOS AutoFill and choose Textem Codes.<br>Do not type or paste the dummy code.</p>
    <form onsubmit="event.preventDefault()"><label for="otp">Verification code</label><p><input id="otp" name="verification-code" autocomplete="one-time-code" inputmode="numeric" maxlength="6" aria-label="Verification code"></p></form>
    <small>Local nonpersistent field with example.com context.<br>No service login, message sending or website submission.<br>Observer logs counts and match status only.</small>
    <script>
    const field=document.getElementById('otp');let phase='CONTROL_BAD';
    function report(event,type='input'){
      const r=field.getBoundingClientRect();
      window.webkit.messageHandlers.field.postMessage({phase,match:field.value==='004321',length:field.value.length,
        trusted:event?.isTrusted===true,bounds:r.left>=0&&r.top>=0&&r.right<=innerWidth&&r.bottom<=innerHeight,
        type:field.autocomplete==='one-time-code'?type:'wrong-content-type'});
    }
    field.addEventListener('input',report);field.addEventListener('change',report);
    field.value='113355';field.dispatchEvent(new Event('input'));
    phase='CONTROL_GOOD';field.value='004321';field.dispatchEvent(new Event('input'));
    field.value='';phase='LIVE';report(null,'ready');field.focus();
    </script>
    """#
}

guard CommandLine.arguments.count == 2 else { exit(2) }
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let consumer = Consumer(output: URL(fileURLWithPath: CommandLine.arguments[1]))
app.delegate = consumer
app.run()
