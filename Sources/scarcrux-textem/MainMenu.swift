import AppKit

// Single-menu layout. macOS mandates the bold app menu (it owns Quit/Hide by
// convention and can't be removed), so rather than scatter Edit/View across
// extra top-level menus we fold everything the app needs — reload + the
// editing commands for composing messages — into that one menu. Key
// equivalents work regardless of which menu holds them.
enum MainMenu {
    static func build(appName: String) -> NSMenu {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu

        // App-action selectors are typed #selectors (no runtime target set, so
        // they still route through the responder chain to the web VC / delegate).
        appMenu.addItem(withTitle: "Sign-in Help…", action: #selector(AppDelegate.showSignInHelp(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "New Conversation", action: #selector(WebViewController.compose(_:)), keyEquivalent: "n")
        let copyCode = appMenu.addItem(withTitle: "Copy Latest Code", action: #selector(WebViewController.copyLatestCode(_:)), keyEquivalent: "c")
        copyCode.keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        if LinkPreviewStore.isEnabled {
            appMenu.addItem(withTitle: "Native Link Previews…", action: #selector(AppDelegate.showLinkPreviews(_:)), keyEquivalent: "")
        }
        appMenu.addItem(.separator())

        // Page reload — needed for the pairing dance and general refresh.
        appMenu.addItem(withTitle: "Reload", action: #selector(WebViewController.reloadPage(_:)), keyEquivalent: "r")
        let hardReload = appMenu.addItem(withTitle: "Reload from Origin", action: #selector(WebViewController.reloadFromOrigin(_:)), keyEquivalent: "r")
        hardReload.keyEquivalentModifierMask = [.command, .shift]

        appMenu.addItem(.separator())

        // Editing commands — first-responder selectors (target nil) so they
        // reach the focused web text field. Without these, ⌘C/⌘V in the
        // message composer aren't reliable.
        appMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = appMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        appMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        appMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        appMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        appMenu.addItem(.separator())

        // Find in page.
        appMenu.addItem(withTitle: "Find…", action: #selector(WebViewController.performFind(_:)), keyEquivalent: "f")
        let findNext = appMenu.addItem(withTitle: "Find Next", action: #selector(WebViewController.findNext(_:)), keyEquivalent: "g")
        findNext.keyEquivalentModifierMask = [.command]
        let findPrev = appMenu.addItem(withTitle: "Find Previous", action: #selector(WebViewController.findPrevious(_:)), keyEquivalent: "g")
        findPrev.keyEquivalentModifierMask = [.command, .shift]

        appMenu.addItem(.separator())

        // Zoom (⌘+ / ⌘- / ⌘0) and always-on-top, routed via the responder chain.
        appMenu.addItem(withTitle: "Zoom In", action: #selector(WebViewController.zoomIn(_:)), keyEquivalent: "+")
        appMenu.addItem(withTitle: "Zoom Out", action: #selector(WebViewController.zoomOut(_:)), keyEquivalent: "-")
        appMenu.addItem(withTitle: "Actual Size", action: #selector(WebViewController.zoomReset(_:)), keyEquivalent: "0")
        appMenu.addItem(withTitle: "Always on Top", action: #selector(WebViewController.toggleAlwaysOnTop(_:)), keyEquivalent: "")

        appMenu.addItem(.separator())

        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        return mainMenu
    }
}
