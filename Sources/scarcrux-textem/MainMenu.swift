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

        // Page reload — needed for the pairing dance and general refresh.
        appMenu.addItem(withTitle: "Reload", action: Selector(("reloadPage:")), keyEquivalent: "r")
        let hardReload = appMenu.addItem(withTitle: "Reload from Origin", action: Selector(("reloadFromOrigin:")), keyEquivalent: "r")
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

        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        return mainMenu
    }
}
