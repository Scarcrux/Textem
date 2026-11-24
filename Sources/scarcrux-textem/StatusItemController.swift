import AppKit

// Menu-bar (NSStatusItem) presence: unread count, account switcher, and the
// background/launch toggles. Always present, so the app has a menu-bar home
// whether or not the Dock icon is visible.
@MainActor
final class StatusItemController: NSObject {
    struct Actions {
        let onShow: () -> Void
        let onLock: () -> Void
        let onSwitchAccount: (UUID) -> Void
        let onAddAccount: () -> Void
        let onRenameAccount: () -> Void
        let onRemoveAccount: () -> Void
    }

    private let statusItem: NSStatusItem
    private let actions: Actions
    private var unreadCount = 0
    private var unreadItem: NSMenuItem?

    init(actions: Actions) {
        self.actions = actions
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "message.fill", accessibilityDescription: "Textem")
            image?.isTemplate = true
            button.image = image
        }
        rebuild()
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: Preferences.settingsChanged, object: nil
        )
    }

    func updateUnread(_ count: Int) {
        unreadCount = count
        statusItem.button?.title = count > 0 ? " \(count)" : ""
        unreadItem?.title = count > 0 ? "\(count) unread" : "No unread messages"
    }

    // Rebuild the whole menu (call after accounts change).
    func rebuild() {
        let menu = NSMenu()

        let show = NSMenuItem(title: "Show Textem", action: #selector(showApp), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        if AppLock.shared.isEnabled && !AppLock.shared.isLocked {
            menu.addItem(actionItem("Lock Textem", #selector(lockApp)))
        }

        let unread = NSMenuItem(title: unreadCount > 0 ? "\(unreadCount) unread" : "No unread messages", action: nil, keyEquivalent: "")
        unread.isEnabled = false
        unreadItem = unread
        menu.addItem(unread)

        if !AppLock.shared.isLocked {
            // Accounts section.
            let store = AccountStore.shared
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Accounts", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for account in store.accounts {
                let item = NSMenuItem(title: account.name, action: #selector(switchAccount(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = account.id.uuidString
                item.state = account.id == store.activeID ? .on : .off
                menu.addItem(item)
            }
            if store.canAddAccounts {
                menu.addItem(actionItem("Add Account…", #selector(addAccount)))
            }
            menu.addItem(actionItem("Rename Current Account…", #selector(renameAccount)))
            if store.accounts.count > 1 {
                menu.addItem(actionItem("Remove Current Account…", #selector(removeAccount)))
            }

        }

        // Reachable from here because in menu-bar-only mode there is no app
        // menu, so this is the only route to Settings without the window.
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        settings.target = NSApp.delegate
        menu.addItem(settings)

        menu.addItem(.separator())
        menu.addItem(toggle("Launch at Login", #selector(toggleLaunchAtLogin), LoginItem.isEnabled))
        menu.addItem(toggle("Menu Bar Only", #selector(toggleMenuBarOnly), Preferences.menuBarOnly))
        menu.addItem(toggle("Mute Notifications", #selector(toggleMute), Preferences.notificationsMuted))
        menu.addItem(toggle("Quit When Window Closed", #selector(toggleQuitOnClose), Preferences.quitOnClose))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Textem", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func toggle(_ title: String, _ action: Selector, _ on: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    @objc private func showApp() { actions.onShow() }
    @objc private func lockApp() { actions.onLock() }

    @objc private func settingsChanged() { rebuild() }

    @objc private func switchAccount(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        actions.onSwitchAccount(id)
    }

    @objc private func addAccount() { actions.onAddAccount() }
    @objc private func renameAccount() { actions.onRenameAccount() }
    @objc private func removeAccount() { actions.onRemoveAccount() }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        LoginItem.set(sender.state != .on)
        sender.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func toggleMenuBarOnly(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        Preferences.menuBarOnly = enabled
        sender.state = enabled ? .on : .off
        NSApp.setActivationPolicy(enabled ? .accessory : .regular)
        if !enabled { actions.onShow() }
    }

    @objc private func toggleMute(_ sender: NSMenuItem) {
        let muted = sender.state != .on
        Preferences.notificationsMuted = muted
        sender.state = muted ? .on : .off
    }

    @objc private func toggleQuitOnClose(_ sender: NSMenuItem) {
        let quit = sender.state != .on
        Preferences.quitOnClose = quit
        sender.state = quit ? .on : .off
    }
}
