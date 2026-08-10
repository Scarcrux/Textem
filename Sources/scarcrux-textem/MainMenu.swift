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

        appMenu.addItem(withTitle: "Sign-in Help…", action: Selector(("showSignInHelp:")), keyEquivalent: "")
        appMenu.addItem(withTitle: "New Conversation", action: Selector(("compose:")), keyEquivalent: "n")
        appMenu.addItem(withTitle: "Settings…", action: Selector(("showSettings:")), keyEquivalent: ",")
        appMenu.addItem(.separator())

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

        // Find in page.
        appMenu.addItem(withTitle: "Find…", action: Selector(("performFind:")), keyEquivalent: "f")
        let findNext = appMenu.addItem(withTitle: "Find Next", action: Selector(("findNext:")), keyEquivalent: "g")
        findNext.keyEquivalentModifierMask = [.command]
        let findPrev = appMenu.addItem(withTitle: "Find Previous", action: Selector(("findPrevious:")), keyEquivalent: "g")
        findPrev.keyEquivalentModifierMask = [.command, .shift]

        appMenu.addItem(.separator())

        // Zoom (⌘+ / ⌘- / ⌘0) and always-on-top, routed via the responder chain.
        appMenu.addItem(withTitle: "Zoom In", action: Selector(("zoomIn:")), keyEquivalent: "+")
        appMenu.addItem(withTitle: "Zoom Out", action: Selector(("zoomOut:")), keyEquivalent: "-")
        appMenu.addItem(withTitle: "Actual Size", action: Selector(("zoomReset:")), keyEquivalent: "0")
        appMenu.addItem(withTitle: "Always on Top", action: Selector(("toggleAlwaysOnTop:")), keyEquivalent: "")

        appMenu.addItem(.separator())

        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        return mainMenu
    }
}
