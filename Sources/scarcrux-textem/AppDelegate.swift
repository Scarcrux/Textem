import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?

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

        // Native notifications: clicking a banner refocuses the window.
        NotificationManager.shared.configure { [weak self] in
            self?.showMainWindow()
        }
        NotificationManager.shared.requestAuthorization()
    }

    // MARK: Account switching

    private func switchAccount(_ id: UUID) {
        AccountStore.shared.setActive(id)
        windowController?.switchTo(AccountStore.shared.active)
        statusItemController?.rebuild()
        showMainWindow()
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
        guard AccountStore.shared.accounts.count > 1 else { return }
        let alert = NSAlert()
        alert.messageText = "Remove “\(current.name)”?"
        alert.informativeText = "This signs the account out and deletes its local session on this Mac."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        AccountStore.shared.remove(current.id)
        switchAccount(AccountStore.shared.active.id)
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
