import AppKit
import XCTest
@testable import scarcrux_textem

@MainActor
final class MainMenuTests: XCTestCase {
    private func titles() throws -> [String] {
        let menu = try XCTUnwrap(MainMenu.build(appName: "Textem").items.first?.submenu)
        return menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
    }

    func testStandardItemsLeadAndEverydayCommandsPrecedePhoneTools() throws {
        let titles = try titles()
        XCTAssertEqual(Array(titles.prefix(4)), ["About Textem", "-", "Settings…", "-"])
        let compose = try XCTUnwrap(titles.firstIndex(of: "New Conversation"))
        let phone = try XCTUnwrap(titles.firstIndex(of: "Shared Phone Images…"))
        XCTAssertLessThan(compose, phone)
        XCTAssertEqual(titles.last, "Quit Textem")
    }

    func testNoCommandWasDroppedByRegrouping() throws {
        let titles = Set(try titles())
        for expected in ["Sign-in Help…", "New Conversation", "Copy Latest Code", "Settings…",
                         "Send Test Notification", "Phone-only Message Preview…", "Shared Phone Images…",
                         "Phone Notification Preview…", "Reload", "Reload from Origin", "Find…",
                         "Zoom In", "Always on Top", "Hide Textem", "Quit Textem"] {
            XCTAssertTrue(titles.contains(expected), expected)
        }
    }

    func testEveryCommandHasAnAction() throws {
        let menu = try XCTUnwrap(MainMenu.build(appName: "Textem").items.first?.submenu)
        for item in menu.items where !item.isSeparatorItem { XCTAssertNotNil(item.action, item.title) }
    }
}
