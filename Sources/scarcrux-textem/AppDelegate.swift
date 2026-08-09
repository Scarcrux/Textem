import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(appName: "Textem")

        let controller = MainWindowController()
        windowController = controller

        // Route unread-count changes to the dock badge (in the web VC) and the
        // menu-bar item.
        controller.webViewController.onUnreadCountChanged = { [weak self] count in
            self?.statusItemController?.updateUnread(count)
        }

        // Menu-bar presence + background/launch toggles.
        statusItemController = StatusItemController(onShow: { [weak self] in
            self?.showMainWindow()
        })

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
