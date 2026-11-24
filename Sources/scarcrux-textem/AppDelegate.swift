import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let appLock = AppLock.shared
    private var windowController: MainWindowController?
    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var activityMonitor: Any?
    private var migrationSheet: NSWindow?
    private var launchFinished = false
    private var globalHotkey: GlobalHotkey?
    private var globalCodeHotkey: GlobalHotkey?

    var isGlobalCodeShortcutRegistered: Bool { globalCodeHotkey?.isRegistered == true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.arguments.contains("--offline") { OfflineMode.setEnabled(true) }
        NativeAutoFillCoordinator.shared.start()
        NSApp.mainMenu = MainMenu.build(appName: "Textem")
        NotificationCenter.default.addObserver(forName: Preferences.settingsChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let menu = NSApp.mainMenu { MainMenu.applyPhoneTools(visible: Preferences.showPhoneTools, to: menu) }
            }
        }
        AppUpdates.shared.start()
        if ProcessInfo.processInfo.arguments.contains("--check-app-updates") {
            try? UpdateDiagnostics.save(UpdateDiagnostics.collect(AppUpdates.shared))
        }
        NSApp.servicesMenu = NSApp.mainMenu?.items.first?.submenu?.item(withTitle: "Services")?.submenu
        NSApp.windowsMenu = NSApp.mainMenu?.item(withTitle: "Window")?.submenu
        NSApp.helpMenu = NSApp.mainMenu?.item(withTitle: "Help")?.submenu
        if let accounts = NSApp.mainMenu?.item(withTitle: "Accounts")?.submenu {
            accounts.delegate = self
            menuNeedsUpdate(accounts)
        }

        let controller = MainWindowController()
        windowController = controller
        appLock.onLockChanged = { [weak self] in self?.appLockChanged() }
        activityMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .mouseMoved,
        ]) { [weak self] event in
            MainActor.assumeIsolated { self?.appLock.noteActivity() }
            return event
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                      NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(self, selector: #selector(lockForSessionChange(_:)), name: event, object: nil)
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(lockForSessionChange(_:)),
            name: Notification.Name("com.apple.screenIsLocked"), object: nil, suspensionBehavior: .deliverImmediately)
        NotificationCenter.default.addObserver(self, selector: #selector(mainWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: controller.window)
        NotificationCenter.default.addObserver(self, selector: #selector(mainWindowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: controller.window)
        NotificationCenter.default.addObserver(self, selector: #selector(mainWindowWasMinimized(_:)),
            name: NSWindow.didMiniaturizeNotification, object: controller.window)
        NotificationCenter.default.addObserver(self, selector: #selector(mainWindowWasRestored(_:)),
            name: NSWindow.didDeminiaturizeNotification, object: controller.window)

        // Route unread-count changes to the dock badge (in the web VC) and the
        // menu-bar item. Set on the window controller so it survives account
        // switches.
        controller.onUnreadCountChanged = { [weak self] count in
            self?.statusItemController?.updateUnread(count)
        }

        // Menu-bar presence + account switcher + background/launch toggles.
        statusItemController = StatusItemController(actions: .init(
            onShow: { [weak self] in self?.showMainWindow() },
            onLock: { [weak self] in self?.lockTextem(nil) },
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

        if ProcessInfo.processInfo.environment["TEXTEM_PHONE_IMAGE_CHECK"] == "1" { showPhoneImages(nil) }

        // Native notifications: click focuses the window; inline reply routes
        // to the active account's web view.
        NotificationManager.shared.configure(
            onOpen: { [weak self] accountID, conversationID in
                self?.openNotification(accountID: accountID, conversationID: conversationID)
            },
            onReply: { [weak self] text, accountID, conversationID in
                self?.replyFromNotification(
                    text, accountID: accountID, conversationID: conversationID)
            },
            onUnlockRequired: { [weak self] in
                guard let self else { return false }
                self.showMainWindow()
                return await self.appLock.unlock()
            }
        )
        if appLock.isLocked { NotificationManager.shared.hideDeliveredForAppLock() }
        // Let a migrated user choose in the sheet before macOS asks again.
        if !MigrationFollowUp.isAvailable() { NotificationManager.shared.requestAuthorization() }
        if ProcessInfo.processInfo.arguments.contains("--check-phone-connection") {
            Task { await runPhoneConnectionCheck(present: false) }
        }
        if ProcessInfo.processInfo.environment["TEXTEM_REPLY_INSPECT"] == "1" {
            NotificationManager.shared.inspectLatestNotifiedThread()
        }
        if ProcessInfo.processInfo.environment["TEXTEM_NOTIFICATION_PROBE"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                NotificationManager.shared.sendTestNotification()
            }
        }

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
        if UserDefaults.standard.bool(forKey: "globalCopyCode") {
            configureGlobalCodeShortcut(enabled: true)
        }

        if ProcessInfo.processInfo.arguments.contains("--check-offline-mode") {
            try? OfflineDiagnostics.save(OfflineDiagnostics.collect(controller))
        }
        // First-run: steer the user away from the passkey dead-end.
        launchFinished = true
        offerUnlockForFocusedWindow()
        if !Preferences.hasSeenOnboarding && !appLock.isLocked {
            showOnboarding()
        } else {
            offerMigrationFollowUp()
        }
    }

    @discardableResult
    func configureGlobalCodeShortcut(enabled: Bool) -> Bool {
        if !enabled {
            globalCodeHotkey?.unregister()
            globalCodeHotkey = nil
            return true
        }
        if isGlobalCodeShortcutRegistered { return true }
        return registerCodeShortcut(.savedCopyCode(), keepRegistered: true)
    }

    func changeGlobalCodeShortcut(to shortcut: GlobalHotkey.Shortcut) -> Bool {
        let enabled = UserDefaults.standard.bool(forKey: "globalCopyCode")
        guard registerCodeShortcut(shortcut, keepRegistered: enabled) else { return false }
        shortcut.saveCopyCode()
        return true
    }

    private func registerCodeShortcut(_ combination: GlobalHotkey.Shortcut, keepRegistered: Bool) -> Bool {
        guard !combination.matches(.showTextem) else { return false }
        if keepRegistered, let active = globalCodeHotkey, active.shortcut.matches(combination) {
            return true
        }
        let candidate = GlobalHotkey(shortcut: combination) { [weak self] in
            Task { await self?.copyFreshCodeFromShortcut() }
        }
        guard candidate.register() else { return false }
        if keepRegistered {
            globalCodeHotkey?.unregister()
            globalCodeHotkey = candidate
        } else {
            candidate.unregister()
        }
        return true
    }

    private func copyFreshCodeFromShortcut() async {
        guard isGlobalCodeShortcutRegistered,
              await appLock.authorizeAction(asking: {
                  self.showMainWindow()
                  return await self.appLock.unlock()
              }), !appLock.isLocked, isGlobalCodeShortcutRegistered else { return }
        guard let code = windowController?.webViewController.freshObservedCode() else {
            NSSound.beep()
            NotificationManager.shared.notifyInfo("No fresh verification code in the active Textem account.")
            return
        }
        CodeClipboard.copy(code)
        NotificationManager.shared.notifyInfo("Verification code copied")
    }

    @objc func lockTextem(_ sender: Any?) {
        appLock.lock()
    }

    @objc private func lockForSessionChange(_ notification: Notification) {
        appLock.lock()
    }

    func applicationDidResignActive(_ notification: Notification) {
        appLock.setAway(true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        appLock.setAway(windowController?.window?.isVisible != true || windowController?.window?.isMiniaturized == true)
        offerUnlockForFocusedWindow()
    }

    @objc private func mainWindowDidBecomeKey(_ notification: Notification) {
        if NSApp.isActive { appLock.setAway(false) }
        offerUnlockForFocusedWindow()
    }

    private func offerUnlockForFocusedWindow() {
        guard launchFinished, appLock.isLocked else { return }
        Task { [weak self] in
            guard let self, NSApp.isActive, let window = self.windowController?.window,
                  window.isKeyWindow, window.isVisible, !window.isMiniaturized else { return }
            await self.appLock.promptToUnlockOnFocus()
        }
    }

    @objc private func mainWindowWillClose(_ notification: Notification) {
        appLock.cancelAuthentication()
        appLock.setAway(true)
    }

    @objc private func mainWindowWasMinimized(_ notification: Notification) {
        appLock.cancelAuthentication()
        appLock.setAway(true)
    }

    @objc private func mainWindowWasRestored(_ notification: Notification) {
        appLock.setAway(!NSApp.isActive)
    }

    private func appLockChanged() {
        windowController?.refreshLockPresentation()
        if appLock.isLocked {
            NotificationManager.shared.hideDeliveredForAppLock()
            settingsWindowController?.close()
            phoneNotificationWindow?.close()
            onboardingWindowController?.close()
            if NSApp.modalWindow != nil { NSApp.abortModal() }
        } else if launchFinished && !Preferences.hasSeenOnboarding {
            showOnboarding()
        } else {
            offerMigrationFollowUp()
        }
        statusItemController?.rebuild()
    }

    private func requireUnlocked() -> Bool {
        guard appLock.isLocked else { return true }
        showMainWindow()
        return false
    }

    @objc func showMigrationFollowUp(_ sender: Any?) {
        guard requireUnlocked(), MigrationFollowUp.isAvailable() else { return }
        showMainWindow()
        presentMigrationFollowUp()
    }

    private func offerMigrationFollowUp() {
        guard !appLock.isLocked, launchFinished, Preferences.hasSeenOnboarding, MigrationFollowUp.shouldPresent() else { return }
        presentMigrationFollowUp()
    }

    private func presentMigrationFollowUp() {
        guard migrationSheet == nil, let parent = windowController?.window,
              parent.isVisible, parent.attachedSheet == nil else { return }
        let hosting = NSHostingController(rootView: MigrationFollowUpSheet(onDone: { [weak self, weak parent] in
            guard let sheet = self?.migrationSheet else { return }
            parent?.endSheet(sheet)
        }, showAutoFill: NativeCodeRuntime.available))
        let sheet = NSWindow(contentViewController: hosting)
        sheet.title = "After Updating Textem"
        migrationSheet = sheet
        parent.beginSheet(sheet) { [weak self] _ in self?.migrationSheet = nil }
        MigrationFollowUp.markOffered()
    }

    @objc func showSignInHelp(_ sender: Any?) {
        if requireUnlocked() { showOnboarding() }
    }

    @objc func checkForUpdates(_ sender: Any?) { AppUpdates.shared.check() }

    @objc func toggleOfflineMode(_ sender: Any?) { OfflineMode.setEnabled(!OfflineMode.enabled) }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(lockTextem(_:)) { return appLock.isEnabled && !appLock.isLocked }
        if menuItem.action == #selector(toggleOfflineMode(_:)) { menuItem.state = OfflineMode.enabled ? .on : .off; return true }
        if OfflineMode.enabled && [#selector(dockCompose), #selector(showPhoneNotification(_:)), #selector(checkPhoneConnection(_:))].contains(menuItem.action) { return false }
        return menuItem.action == #selector(checkForUpdates(_:)) ? AppUpdates.shared.canCheck : true
    }

    @objc func sendTestNotification(_ sender: Any?) {
        NotificationManager.shared.sendTestNotification()
    }

    private func showOnboarding() {
        let controller = OnboardingWindowController(onDone: { [weak self] in
            Preferences.hasSeenOnboarding = true
            self?.offerMigrationFollowUp()
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

        guard !appLock.isLocked else { return menu }
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
        guard requireUnlocked() else { return }
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
        guard requireUnlocked(), AccountStore.shared.accounts.contains(where: { $0.id == id }) else { return false }
        if AccountStore.shared.activeID != id {
            AccountStore.shared.setActive(id)
            windowController?.switchTo(AccountStore.shared.active)
        }
        statusItemController?.rebuild()
        if show { showMainWindow() }
        return true
    }

    private func openNotification(accountID: UUID?, conversationID: String?) {
        guard !appLock.isLocked else { return }
        if let accountID, !switchAccount(accountID, show: false) {
            NotificationManager.shared.notifyInfo(
                "That notification belongs to an account that has been removed.")
            return
        }
        windowController?.webViewController.openConversation(conversationID)
        showMainWindow()
    }

    private func replyFromNotification(_ text: String, accountID: UUID?,
                                       conversationID: String?) {
        guard !appLock.isLocked else { return }
        if let accountID, !switchAccount(accountID, show: false) {
            NotificationManager.shared.notifyInfo(
                "Reply not sent: its account has been removed.")
            return
        }
        windowController?.webViewController.quickReply(
            text, conversationID: conversationID)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Accounts" else { return }
        if appLock.isLocked {
            menu.removeAllItems()
            return
        }
        let store = AccountStore.shared
        MainMenu.populateAccounts(menu, accounts: store.accounts, activeID: store.activeID, canAdd: store.canAddAccounts)
    }

    @objc func switchAccountFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        _ = switchAccount(id)
    }
    @objc func addAccountFromMenu(_ sender: Any?) { addAccount() }
    @objc func renameAccountFromMenu(_ sender: Any?) { renameAccount() }
    @objc func removeAccountFromMenu(_ sender: Any?) { removeAccount() }

    private func addAccount() {
        guard requireUnlocked() else { return }
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
        guard requireUnlocked() else { return }
        let current = AccountStore.shared.active
        guard let name = promptForText(title: "Rename Account", message: "New name:", defaultValue: current.name),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        AccountStore.shared.rename(current.id, to: name)
        statusItemController?.rebuild()
        windowController?.window?.title = "Textem — \(name)"
    }

    private func removeAccount() {
        guard requireUnlocked() else { return }
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
        guard !appLock.isLocked else { return }
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func showSettings(_ sender: Any?) {
        guard requireUnlocked() else { return }
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.center()
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        do {
            guard try PhoneRecoveryCheck.consumeRequest(filenames) else { sender.reply(toOpenOrPrint: .failure); return }
            sender.reply(toOpenOrPrint: .success)
            Task { await runPhoneConnectionCheck(present: false) }
        } catch { sender.reply(toOpenOrPrint: .failure) }
    }

    @objc func checkPhoneConnection(_ sender: Any?) {
        guard requireUnlocked() else { return }
        Task { await runPhoneConnectionCheck(present: true) }
    }
    private func runPhoneConnectionCheck(present: Bool) async {
        let report = await PhoneRecoveryCheck.collect(discover: { await CompanionDiscovery.resolve(fingerprint: $0) }, history: { try await CompanionHistoryTransport().fetch() }, pane: { [weak self] in
            await self?.windowController?.webViewController.phoneRecoveryPaneEvidence() ?? PhoneRecoveryCheck.Pane()
        })
        do { try PhoneRecoveryCheck.save(report) }
        catch { if present { presentInfo("Couldn’t save the private connection check.") }; return }
        if present && !appLock.isLocked {
            if report.state == .connected {
                presentInfo("Phone connection working. Received \(report.previews) captured previews from \(report.sources) sources, including \(report.pictures) pictures. This does not establish complete history.")
            } else {
                presentInfo(report.state.message + " Saved previews remain available. Check Phone connection in the preview pane and that the phone connection is running.")
            }
        }
    }

    @objc func showPhoneImages(_ sender: Any?) {
        guard requireUnlocked() else { return }
        if OfflineMode.enabled { windowController?.showOfflineLibrary(pictures: true); showMainWindow(); return }
        windowController?.webViewController.showPhoneImages()
        showMainWindow()
    }

    @objc func showSavedPhoneConversations(_ sender: Any?) {
        guard requireUnlocked() else { return }
        if OfflineMode.enabled { windowController?.showOfflineLibrary(); showMainWindow(); return }
        windowController?.webViewController.showSavedPhoneConversations()
        showMainWindow()
    }

    private var phoneNotificationWindow: PhoneNotificationWindowController?
    @objc func showPhoneNotification(_ sender: Any?) {
        guard requireUnlocked() else { return }
        guard !OfflineMode.enabled else { return }
        if phoneNotificationWindow == nil { phoneNotificationWindow = PhoneNotificationWindowController() }
        phoneNotificationWindow?.showWindow(nil); phoneNotificationWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let activityMonitor { NSEvent.removeMonitor(activityMonitor) }
        globalHotkey?.unregister()
        globalCodeHotkey?.unregister()
        PhoneImageADBClient.shared.stop()
    }

    private func showMainWindow() {
        guard let controller = windowController else { return }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        appLock.setAway(false)
        offerMigrationFollowUp()
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
