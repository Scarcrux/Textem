import AppKit
import XCTest
@testable import scarcrux_textem

@MainActor final class MainMenuTests: XCTestCase {
    private func commands(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in
            if let submenu = item.submenu { return commands(submenu) }
            return item.isSeparatorItem ? [] : [item]
        }
    }
    func testNativeGroupsKeepTheAppMenuFocused() throws {
        let root = MainMenu.build(appName: "Textem")
        XCTAssertEqual(root.items.map(\.title), ["Textem", "File", "Edit", "View", "Accounts", "Phone", "Window", "Help"])
        let app = try XCTUnwrap(root.items.first?.submenu)
        XCTAssertEqual(app.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["About Textem", "Settings…", "Services", "Hide Textem", "Hide Others", "Show All", "Quit Textem"])
        for (group, title) in [("File", "New Conversation"), ("Edit", "Copy Latest Code"), ("Edit", "Find…"),
                               ("View", "Reload"), ("Phone", "Shared Phone Images…"), ("Window", "Always on Top"), ("Help", "Sign-in Help…")] {
            XCTAssertNotNil(root.item(withTitle: group)?.submenu?.item(withTitle: title))
        }
        XCTAssertNotNil(root.item(withTitle: "Help")?.submenu?.item(withTitle: "Diagnostics")?.submenu?.item(withTitle: "Send Test Notification"))
    }
    func testEveryExistingCommandAndResponderRouteIsPreserved() {
        let items = commands(MainMenu.build(appName: "Textem"))
        let titles = Set(items.map(\.title))
        for title in ["About Textem", "Settings…", "New Conversation", "Copy Latest Code", "Sign-in Help…", "Send Test Notification",
                      "Phone-only Message Preview…", "Shared Phone Images…", "Phone Notification Preview…", "Reload", "Reload from Origin",
                      "Undo", "Redo", "Cut", "Copy", "Paste", "Select All", "Find…", "Find Next", "Find Previous",
                      "Zoom In", "Zoom Out", "Actual Size", "Always on Top", "Hide Textem", "Hide Others", "Quit Textem"] {
            XCTAssertTrue(titles.contains(title), title)
        }
        for item in items { XCTAssertNotNil(item.action, item.title); XCTAssertNil(item.target, item.title) }
    }
    func testShortcutsRemainDistinctAndKeepTheirModifiers() throws {
        let items = commands(MainMenu.build(appName: "Textem"))
        let keyed = items.filter { !$0.keyEquivalent.isEmpty }
        let signatures = keyed.map { $0.keyEquivalent + ":" + String($0.keyEquivalentModifierMask.rawValue) }
        XCTAssertEqual(signatures.count, Set(signatures).count)
        for (title, key, modifiers): (String, String, NSEvent.ModifierFlags) in [
            ("New Conversation", "n", [.command]), ("Copy", "c", [.command]), ("Paste", "v", [.command]),
            ("Copy Latest Code", "c", [.command, .shift]), ("Redo", "z", [.command, .shift]),
            ("Reload from Origin", "r", [.command, .shift]), ("Find Previous", "g", [.command, .shift]),
            ("Hide Others", "h", [.command, .option]), ("Settings…", ",", [.command]), ("Close Window", "w", [.command])] {
            let item = try XCTUnwrap(items.first { $0.title == title })
            XCTAssertEqual(item.keyEquivalent, key); XCTAssertEqual(item.keyEquivalentModifierMask, modifiers)
        }
    }
    func testAccountMenuRebuildsSelectionAndGuardsWithoutTouchingStorage() throws {
        let a = Account(name: "Example Personal", storeIdentifier: nil)
        let b = Account(name: "Example Work", storeIdentifier: UUID())
        let menu = NSMenu(title: "Accounts")
        MainMenu.populateAccounts(menu, accounts: [a, b], activeID: b.id, canAdd: true)
        XCTAssertEqual(menu.items.prefix(2).map(\.state), [.off, .on])
        XCTAssertEqual(menu.items[1].representedObject as? String, b.id.uuidString)
        XCTAssertEqual(menu.items[1].action, #selector(AppDelegate.switchAccountFromMenu(_:)))
        XCTAssertTrue(try XCTUnwrap(menu.item(withTitle: "Remove Current Account…")).isEnabled)
        MainMenu.populateAccounts(menu, accounts: [a], activeID: a.id, canAdd: false)
        XCTAssertNil(menu.item(withTitle: b.name)); XCTAssertEqual(menu.items[0].state, .on)
        XCTAssertFalse(try XCTUnwrap(menu.item(withTitle: "Add Account…")).isEnabled)
        XCTAssertFalse(try XCTUnwrap(menu.item(withTitle: "Remove Current Account…")).isEnabled)
        let delegate = AppDelegate()
        for item in menu.items where !item.isSeparatorItem { XCTAssertTrue(delegate.responds(to: try XCTUnwrap(item.action))) }
    }
}
