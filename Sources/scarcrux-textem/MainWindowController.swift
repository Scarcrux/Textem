import AppKit
import SwiftUI
import WebKit

final class MainWindowController: NSWindowController {
    private let appLock: AppLock
    private let initialURL: URL?
    private let offlineLibrary: (UUID) -> OfflineLibraryModel
    private var displayedAccount: Account
    private let storeForAccount: (Account) -> WKWebsiteDataStore
    private(set) var offlineModel: OfflineLibraryModel?
    private(set) var webViewController: WebViewController

    // Persisted across account switches and applied to the active web VC.
    var onUnreadCountChanged: ((Int) -> Void)? {
        didSet {
            webViewController.onUnreadCountChanged = onUnreadCountChanged
            if OfflineMode.enabled { clearUnreadIndicators() }
        }
    }

    init(account: Account? = nil, storeForAccount: @escaping (Account) -> WKWebsiteDataStore = { AccountStore.shared.dataStore(for: $0) },
         initialURL: URL? = nil, appLock: AppLock = .shared, offlineLibrary: @escaping (UUID) -> OfflineLibraryModel = { OfflineLibraryModel(accountID: $0) }) {
        let account = account ?? AccountStore.shared.active
        self.displayedAccount = account; self.storeForAccount = storeForAccount
        self.appLock = appLock
        self.initialURL = initialURL; self.offlineLibrary = offlineLibrary
        webViewController = WebViewController(
            accountID: account.id,
            dataStore: storeForAccount(account), initialURL: initialURL)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Textem"
        window.titlebarAppearsTransparent = false
        // Keep the window above Google Messages' responsive breakpoint so it
        // doesn't collapse from the two-column (list + thread) layout down to
        // a single column.
        window.minSize = NSSize(width: 920, height: 560)
        window.center()
        // Persist window position/size across launches.
        window.setFrameAutosaveName("TextemMainWindow")

        super.init(window: window)
        presentContent(for: account)
        NotificationCenter.default.addObserver(self, selector: #selector(modeChanged), name: OfflineMode.changed, object: nil)
    }

    // Swap the content web view for a different account's session.
    func switchTo(_ account: Account) {
        displayedAccount = account
        let old = webViewController
        let new = WebViewController(
            accountID: account.id,
            dataStore: storeForAccount(account), initialURL: initialURL)
        new.onUnreadCountChanged = onUnreadCountChanged
        webViewController = new
        old.teardown()
        presentContent(for: account)
        if !appLock.isLocked { window?.title = OfflineMode.enabled ? "Textem — Offline Mode" : "Textem — \(account.name)" }
    }

    func refreshLockPresentation() {
        if appLock.isLocked {
            webViewController.prepareForAppLock()
            if let sheet = window?.attachedSheet { window?.endSheet(sheet) }
        }
        presentContent(for: displayedAccount)
    }

    private func presentContent(for account: Account) {
        let frameBeforeSwap = appLock.isEnabled ? window?.frame : nil
        defer {
            if let frameBeforeSwap, window?.frame != frameBeforeSwap {
                window?.setFrame(frameBeforeSwap, display: true)
            }
        }
        if appLock.isLocked {
            offlineModel = nil
            window?.title = "Textem — Locked"
            window?.makeFirstResponder(nil)
            let cover = NSHostingController(rootView: AppLockView(lock: appLock))
            // The cover fills the existing window instead of sizing it to its
            // intrinsic text width.
            cover.sizingOptions = []
            if let size = window?.contentView?.bounds.size { cover.view.frame.size = size }
            window?.contentViewController = cover
            return
        }
        if OfflineMode.enabled {
            clearUnreadIndicators()
            let model = offlineLibrary(account.id)
            offlineModel = model
            window?.contentViewController = NSHostingController(rootView: OfflineLibraryView(model: model,
                goOnline: { OfflineMode.setEnabled(false) }))
            window?.title = "Textem — Offline Mode"
        } else {
            offlineModel = nil
            window?.contentViewController = webViewController
            window?.title = "Textem"
        }
    }
    private func clearUnreadIndicators() {
        NSApp.dockTile.badgeLabel = nil
        onUnreadCountChanged?(0)
    }
    @objc private func modeChanged() {
        let old = webViewController
        let account = displayedAccount
        old.teardown()
        if OfflineMode.enabled { PhoneImageADBClient.shared.stop() }
        webViewController = WebViewController(accountID: account.id, dataStore: storeForAccount(account), initialURL: initialURL)
        webViewController.onUnreadCountChanged = onUnreadCountChanged
        presentContent(for: account)
    }
    func showOfflineLibrary(pictures: Bool = false) {
        offlineModel?.showPictures = pictures
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
