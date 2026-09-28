import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var globalHotkey: GlobalHotkey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(appName: "Textem")

        let controller = MainWindowController()
        windowController = controller

        // Route unread-count changes to the dock badge (in the web VC) and the
        // menu-bar item. Set on the window controller so it survives account
        // switches.
        controller.onUnreadCountChanged = { [weak self] count in
            self?.statusItemController?.updateUnread(count)
        }

        // Menu-bar presence + account switcher + background/launch toggles.
        statusItemController = StatusItemController(actions: .init(
            onShow: { [weak self] in self?.showMainWindow() },
            onSwitchAccount: { [weak self] id in self?.switchAccount(id) },
            onAddAccount: { [weak self] in self?.addAccount() },
            onRenameAccount: { [weak self] in self?.renameAccount() },
            onRemoveAccount: { [weak self] in self?.removeAccount() }
        ))

        // Apply persisted window/dock behavior.
        if Preferences.menuBarOnly {
            NSApp.setActivationPolicy(.accessory)
        }
        if !Preferences.startHidden {
            showMainWindow()
        }

        if LinkPreviewStore.isEnabled {
            showLinkPreviews(nil)
        }

        // Native notifications: click focuses the window; inline reply routes
        // to the active account's web view.
        NotificationManager.shared.configure(
            onOpen: { [weak self] accountID, conversationID in
                self?.openNotification(accountID: accountID, conversationID: conversationID)
            },
            onReply: { [weak self] text, accountID, conversationID in
                self?.replyFromNotification(
                    text, accountID: accountID, conversationID: conversationID)
            }
        )
        NotificationManager.shared.requestAuthorization()

        // System-wide show/hide hotkey (⌥⌘M).
        let hotkey = GlobalHotkey { [weak self] in
            if NSApp.isActive {
                NSApp.hide(nil)
            } else {
                self?.showMainWindow()
            }
        }
        hotkey.register()
        globalHotkey = hotkey

        // First-run: steer the user away from the passkey dead-end.
        if !Preferences.hasSeenOnboarding {
            showOnboarding()
        }
    }

    @objc func showSignInHelp(_ sender: Any?) {
        showOnboarding()
    }

    private func showOnboarding() {
        let controller = OnboardingWindowController(onDone: {
            Preferences.hasSeenOnboarding = true
        })
        onboardingWindowController = controller
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Right-click Dock icon: compose + quick account switch (Texty Pro parity).
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let compose = NSMenuItem(title: "New Conversation", action: #selector(dockCompose), keyEquivalent: "")
        compose.target = self
        menu.addItem(compose)

        let store = AccountStore.shared
        if store.accounts.count > 1 {
            menu.addItem(.separator())
            for account in store.accounts {
                let item = NSMenuItem(title: account.name, action: #selector(dockSwitch(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = account.id.uuidString
                item.state = account.id == store.activeID ? .on : .off
                menu.addItem(item)
            }
        }
        return menu
    }

    @objc private func dockCompose() {
        windowController?.webViewController.compose(nil)
        showMainWindow()
    }

    @objc private func dockSwitch(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        switchAccount(id)
    }

    // MARK: Account switching

    @discardableResult
    private func switchAccount(_ id: UUID, show: Bool = true) -> Bool {
        guard AccountStore.shared.accounts.contains(where: { $0.id == id }) else { return false }
        if AccountStore.shared.activeID != id {
            AccountStore.shared.setActive(id)
            windowController?.switchTo(AccountStore.shared.active)
        }
        statusItemController?.rebuild()
        if show { showMainWindow() }
        return true
    }

    private func openNotification(accountID: UUID?, conversationID: String?) {
        if let accountID, !switchAccount(accountID, show: false) {
            NotificationManager.shared.notifyInfo(
                "That notification belongs to an account that has been removed.")
        }
        windowController?.webViewController.openConversation(conversationID)
        showMainWindow()
    }

    private func replyFromNotification(_ text: String, accountID: UUID?,
                                       conversationID: String?) {
        if let accountID, !switchAccount(accountID, show: false) {
            NotificationManager.shared.notifyInfo(
                "Reply not sent: its account has been removed.")
            return
        }
        windowController?.webViewController.quickReply(
            text, conversationID: conversationID)
    }

    private func addAccount() {
        guard AccountStore.shared.canAddAccounts else {
            presentInfo("Multiple accounts require macOS 14 or later.")
            return
        }
        let suggested = "Account \(AccountStore.shared.accounts.count + 1)"
        guard let name = promptForText(title: "New Account", message: "Name this account:", defaultValue: suggested),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let account = AccountStore.shared.addAccount(name: name)
        switchAccount(account.id)
    }

    private func renameAccount() {
        let current = AccountStore.shared.active
        guard let name = promptForText(title: "Rename Account", message: "New name:", defaultValue: current.name),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        AccountStore.shared.rename(current.id, to: name)
        statusItemController?.rebuild()
        windowController?.window?.title = "Textem — \(name)"
    }

    private func removeAccount() {
        let current = AccountStore.shared.active
        let store = AccountStore.shared
        guard store.accounts.count > 1,
              let fallback = store.accounts.first(where: { $0.id != current.id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove “\(current.name)”?"
        alert.informativeText = "This signs the account out and deletes its local session on this Mac."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Tear down the active web view before asking WebKit to delete its data
        // store. Keep the account entry if deletion fails so the UI never claims
        // a local session was removed when it was not.
        _ = switchAccount(fallback.id)
        store.remove(current.id) { [weak self] error in
            self?.statusItemController?.rebuild()
            if let error {
                self?.presentInfo(
                    "The account was not removed because its local session could not be deleted: \(error.localizedDescription)")
            }
        }
    }

    private func promptForText(title: String, message: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func presentInfo(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.center()
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showLinkPreviews(_ sender: Any?) {
        do {
            try windowController?.webViewController.showLinkPreviewLibrary()
            showMainWindow()
        } catch {
            presentInfo(error.localizedDescription)
        }
    }

    private func showMainWindow() {
        guard let controller = windowController else { return }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Keep running in the background when the window closes, unless the user
    // opted into quit-on-close.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        Preferences.quitOnClose
    }

    // Re-open the window when the dock icon is clicked and nothing is visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
