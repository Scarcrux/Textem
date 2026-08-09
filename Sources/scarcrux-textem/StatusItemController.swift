import AppKit

// Menu-bar (NSStatusItem) presence: shows unread count and hosts the
// background/launch toggles. Always present, so the app has a menu-bar home
// whether or not the Dock icon is visible.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let onShow: () -> Void
    private var unreadItem: NSMenuItem?

    init(onShow: @escaping () -> Void) {
        self.onShow = onShow
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "message.fill", accessibilityDescription: "Textem")
            image?.isTemplate = true
            button.image = image
        }
        buildMenu()
    }

    func updateUnread(_ count: Int) {
        statusItem.button?.title = count > 0 ? " \(count)" : ""
        unreadItem?.title = count > 0 ? "\(count) unread" : "No unread messages"
    }

    private func buildMenu() {
        let menu = NSMenu()

        let show = NSMenuItem(title: "Show Textem", action: #selector(showApp), keyEquivalent: "")
        show.target = self
        menu.addItem(show)

        let unread = NSMenuItem(title: "No unread messages", action: nil, keyEquivalent: "")
        unread.isEnabled = false
        unreadItem = unread
        menu.addItem(unread)

        menu.addItem(.separator())
        menu.addItem(toggle("Launch at Login", #selector(toggleLaunchAtLogin), LoginItem.isEnabled))
        menu.addItem(toggle("Menu Bar Only (hide Dock)", #selector(toggleMenuBarOnly), Preferences.menuBarOnly))
        menu.addItem(toggle("Mute Notifications", #selector(toggleMute), Preferences.notificationsMuted))
        menu.addItem(toggle("Quit When Window Closed", #selector(toggleQuitOnClose), Preferences.quitOnClose))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Textem", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func toggle(_ title: String, _ action: Selector, _ on: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    @objc private func showApp() {
        onShow()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        LoginItem.set(sender.state != .on)
        sender.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func toggleMenuBarOnly(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        Preferences.menuBarOnly = enabled
        sender.state = enabled ? .on : .off
        NSApp.setActivationPolicy(enabled ? .accessory : .regular)
        if !enabled { onShow() }
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
