import AppKit

// Menu-bar (NSStatusItem) presence: unread count, account switcher, and the
// background/launch toggles. Always present, so the app has a menu-bar home
// whether or not the Dock icon is visible.
@MainActor
final class StatusItemController: NSObject {
    struct Actions {
        let onShow: () -> Void
        let onSwitchAccount: (UUID) -> Void
        let onAddAccount: () -> Void
        let onRenameAccount: () -> Void
        let onRemoveAccount: () -> Void
    }

    private let statusItem: NSStatusItem
    private let actions: Actions
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
    }

    func updateUnread(_ count: Int) {
        statusItem.button?.title = count > 0 ? " \(count)" : ""
        unreadItem?.title = count > 0 ? "\(count) unread" : "No unread messages"
    }

    // Rebuild the whole menu (call after accounts change).
    func rebuild() {
        let menu = NSMenu()

        let show = NSMenuItem(title: "Show Textem", action: #selector(showApp), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        let unread = NSMenuItem(title: "No unread messages", action: nil, keyEquivalent: "")
        unread.isEnabled = false
        unreadItem = unread
        menu.addItem(unread)

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

        menu.addItem(.separator())
        menu.addItem(toggle("Launch at Login", #selector(toggleLaunchAtLogin), LoginItem.isEnabled))
        menu.addItem(toggle("Menu Bar Only (hide Dock)", #selector(toggleMenuBarOnly), Preferences.menuBarOnly))
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
