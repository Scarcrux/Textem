import Foundation

// Presentation mode for screenshots: `open -a Textem --args --demo`.
//
// It changes only what is DISPLAYED on the real Google Messages page —
// conversation names, previews, message text, avatars and pictures become
// fictional sample content — so Textem's real window can be shown without
// anyone's messages. Nothing is sent and no message is modified. While it is
// on, notifications and verification-code detection are off (the swapped text
// would otherwise look like new messages). View → Save Demo Screenshot writes
// the page to a private folder for review before any use.
enum DemoMode {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--demo") || capturesAutomatically
    }
    /// `--demo-capture`: demo mode that saves its own screenshots — the
    /// conversation list, then the most recent conversation opened — and
    /// writes `done.json` listing them, so no one has to press anything.
    static var capturesAutomatically: Bool { ProcessInfo.processInfo.arguments.contains("--demo-capture") }

    static var captureDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Textem/DemoCaptures", isDirectory: true)
    }

    /// Writes a capture privately (folder 0700, file 0600) and returns its URL.
    static func save(png: Data, now: Date = Date(), in directory: URL = captureDirectory) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("textem-demo-\(stamp).png")
        guard FileManager.default.createFile(atPath: url.path, contents: png,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    static let samplePeople: [(name: String, preview: String)] = [
        ("Alex Rivera", "Running 10 min late, save me a seat!"),
        ("Jordan Lee", "Photos from the hike are up"),
        ("Mom", "Call me when you land ❤️"),
        ("Sam Patel", "Yes! Tuesday works for me."),
        ("Book Club", "Next pick: The Overstory"),
        ("Taylor Kim", "Haha that's perfect"),
        ("Chris Morgan", "Can you send me the address?"),
        ("Riley Chen", "Thanks again for dinner!"),
        ("Neighborhood Pharmacy", "Your prescription is ready for pickup."),
        ("Casey Brooks", "See you Saturday"),
        ("Morgan Diaz", "Did you see the game last night?"),
        ("Climbing Crew", "Gym at 6? I'll bring the chalk"),
        ("Priya Shah", "Sent you the recipe!"),
        ("Dad", "Proud of you, kiddo"),
        ("Jamie Ortiz", "Lol yes"),
        ("Avery Johnson", "Can we push to 3pm?"),
        ("Noah Williams", "Got the tickets 🎟️"),
        ("Front Desk", "Your package is at the front desk."),
        ("Emma Davis", "Love that idea"),
        ("Leo Martin", "On my way"),
    ]

    static let sampleThread: [String] = [
        "Hey! Are we still on for tonight?",
        "Yes! 7:30 at Luca's?",
        "Perfect. I'll grab a table by the window",
        "Running 10 min late, save me a seat!",
        "No rush 😊",
        "Should I order the garlic knots?",
        "Obviously",
        "Ordered. See you soon!",
    ]

    /// Injected at document end. Re-applies after every page update, so
    /// content Google renders later (scrolling, opening a thread) is covered.
    static var userScript: String {
        let people = samplePeople.map { "[\(jsString($0.name)),\(jsString($0.preview))]" }.joined(separator: ",")
        let thread = sampleThread.map(jsString).joined(separator: ",")
        return """
        (function(){
          if (window.__textemDemo) return; window.__textemDemo = true;
          var people = [\(people)], thread = [\(thread)], realToSample = new Map();
          var style = document.createElement('style');
          style.textContent = 'img,video,canvas{visibility:hidden !important}' +
            'mws-avatar{background:#7cacf8 !important;border-radius:50% !important}';
          document.documentElement.appendChild(style);
          function setText(el, value) {
            if (!el || (el.dataset.textemDemo === value && el.textContent === value)) return;
            // Rewrite the words, not the element: keep Google's inner spans so
            // bubbles keep their colours and shape. First text node gets the
            // sample, the rest are emptied.
            var walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT), node, first = true;
            while ((node = walker.nextNode())) {
              if (!node.nodeValue.trim()) continue;
              node.nodeValue = first ? value : ''; first = false;
            }
            if (first) el.textContent = value;
            el.dataset.textemDemo = value;
          }
          var phone = /\\+?\\d[\\d\\s().-]{6,}\\d/g, email = /[\\w.+-]+@[\\w-]+\\.[\\w.]+/g;
          function scrubTextNodes() {
            var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT), node;
            while ((node = walker.nextNode())) {
              var parent = node.parentElement;
              if (!parent || parent.closest('[data-textem-demo], style, script')) continue;
              var text = node.nodeValue, next = text;
              realToSample.forEach(function(sample, real){ if (real && next.indexOf(real) !== -1) next = next.split(real).join(sample); });
              next = next.replace(phone, '(555) 010-0199').replace(email, 'alex@example.com');
              if (next !== text) node.nodeValue = next;
            }
          }
          function apply() {
            observer.disconnect();
            document.querySelectorAll('mws-conversation-list-item').forEach(function(item, i){
              var person = people[i % people.length];
              var name = item.querySelector('[data-e2e-conversation-name], h3, .name');
              if (name) {
                var real = name.dataset.textemDemo ? null : name.textContent.trim();
                if (real && real.length > 1) realToSample.set(real, person[0]);
                setText(name, person[0]);
              }
              setText(item.querySelector('[data-e2e-conversation-snippet], mws-conversation-snippet'), person[1]);
              item.querySelectorAll('mws-avatar').forEach(function(avatar){
                avatar.querySelectorAll('*').forEach(function(child){
                  if (child.children.length === 0 && child.textContent.trim().length <= 2) setText(child, person[0][0]);
                });
              });
            });
            document.querySelectorAll('mws-text-message-part').forEach(function(part, i){
              setText(part, thread[i % thread.length]);
            });
            scrubTextNodes();
            observer.observe(document.body, {subtree: true, childList: true, characterData: true});
          }
          var pending = false;
          var observer = new MutationObserver(function(){
            if (pending) return; pending = true;
            // A timer, not requestAnimationFrame: WebKit pauses animation
            // frames for windows that aren't on screen.
            setTimeout(function(){ pending = false; apply(); }, 30);
          });
          apply();
        })();
        """
    }

    private static func jsString(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
