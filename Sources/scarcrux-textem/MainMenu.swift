import AppKit

enum MainMenu {
    static func build(appName: String) -> NSMenu {
        let main = NSMenu()
        func section(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title); item.submenu = menu; main.addItem(item)
            return menu
        }
        func command(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
                     _ modifiers: NSEvent.ModifierFlags = [.command]) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
        }
        let app = section(appName)
        command(app, "About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        command(app, "Check for Updates…", #selector(AppDelegate.checkForUpdates(_:)))
        app.addItem(.separator())
        command(app, "Settings…", #selector(AppDelegate.showSettings(_:)), ",")
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services"); app.addItem(services)
        app.addItem(.separator())
        command(app, "Hide \(appName)", #selector(NSApplication.hide(_:)), "h")
        command(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        command(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        command(app, "Quit \(appName)", #selector(NSApplication.terminate(_:)), "q")

        let file = section("File")
        command(file, "New Conversation", #selector(WebViewController.compose(_:)), "n")
        file.addItem(.separator())
        command(file, "Close Window", #selector(NSWindow.performClose(_:)), "w")

        // Nil targets preserve the focused WKWebView composer's responder chain.
        let edit = section("Edit")
        command(edit, "Undo", Selector(("undo:")), "z")
        command(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        command(edit, "Cut", #selector(NSText.cut(_:)), "x")
        command(edit, "Copy", #selector(NSText.copy(_:)), "c")
        command(edit, "Paste", #selector(NSText.paste(_:)), "v")
        command(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        command(edit, "Find…", #selector(WebViewController.performFind(_:)), "f")
        command(edit, "Find Next", #selector(WebViewController.findNext(_:)), "g")
        command(edit, "Find Previous", #selector(WebViewController.findPrevious(_:)), "g", [.command, .shift])
        edit.addItem(.separator())
        command(edit, "Copy Latest Code", #selector(WebViewController.copyLatestCode(_:)), "c", [.command, .shift])

        let view = section("View")
        command(view, "Offline Mode", #selector(AppDelegate.toggleOfflineMode(_:)))
        view.addItem(.separator())
        command(view, "Reload", #selector(WebViewController.reloadPage(_:)), "r")
        command(view, "Reload from Origin", #selector(WebViewController.reloadFromOrigin(_:)), "r", [.command, .shift])
        view.addItem(.separator())
        command(view, "Zoom In", #selector(WebViewController.zoomIn(_:)), "+")
        command(view, "Zoom Out", #selector(WebViewController.zoomOut(_:)), "-")
        command(view, "Actual Size", #selector(WebViewController.zoomReset(_:)), "0")

        // The delegate refreshes this on opening; construction never reads accounts.
        _ = section("Accounts")

        let phone = section("Phone")
        command(phone, "Saved Conversation Previews…", #selector(AppDelegate.showSavedPhoneConversations(_:)))
        command(phone, "Phone-only Message Preview…", #selector(AppDelegate.showLinkPreviews(_:)))
        command(phone, "Shared Phone Images…", #selector(AppDelegate.showPhoneImages(_:)))
        command(phone, "Phone Notification Preview…", #selector(AppDelegate.showPhoneNotification(_:)))

        let window = section("Window")
        command(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        command(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        command(window, "Always on Top", #selector(WebViewController.toggleAlwaysOnTop(_:)))
        window.addItem(.separator())
        command(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))

        let help = section("Help")
        command(help, "Sign-in Help…", #selector(AppDelegate.showSignInHelp(_:)))
        help.addItem(.separator())
        let diagnostics = NSMenuItem(title: "Diagnostics", action: nil, keyEquivalent: "")
        diagnostics.submenu = NSMenu(title: "Diagnostics")
        command(diagnostics.submenu!, "Check Phone Connection…", #selector(AppDelegate.checkPhoneConnection(_:)))
        diagnostics.submenu?.addItem(.separator())
        command(diagnostics.submenu!, "Send Test Notification", #selector(AppDelegate.sendTestNotification(_:)))
        help.addItem(diagnostics)
        return main
    }

    static func populateAccounts(_ menu: NSMenu, accounts: [Account], activeID: UUID, canAdd: Bool) {
        menu.removeAllItems(); menu.autoenablesItems = false
        for account in accounts {
            let item = menu.addItem(withTitle: account.name, action: #selector(AppDelegate.switchAccountFromMenu(_:)), keyEquivalent: "")
            item.representedObject = account.id.uuidString
            item.state = account.id == activeID ? .on : .off
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Add Account…", action: #selector(AppDelegate.addAccountFromMenu(_:)), keyEquivalent: "").isEnabled = canAdd
        menu.addItem(withTitle: "Rename Current Account…", action: #selector(AppDelegate.renameAccountFromMenu(_:)), keyEquivalent: "").isEnabled = !accounts.isEmpty
        menu.addItem(withTitle: "Remove Current Account…", action: #selector(AppDelegate.removeAccountFromMenu(_:)), keyEquivalent: "").isEnabled = accounts.count > 1
    }
}
