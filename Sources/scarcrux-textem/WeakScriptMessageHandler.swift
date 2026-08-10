import WebKit

// WKUserContentController retains its script-message handlers strongly, which
// otherwise forms a retain cycle (controller -> handler -> webView ->
// configuration -> controller) that leaks a whole WebViewController every time
// we switch accounts. This weak proxy breaks the cycle.
@MainActor
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var delegate: WKScriptMessageHandler?

    init(_ delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(_ userContentController: WKUserContentController,
                              didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}
