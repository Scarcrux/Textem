import AppKit
import Carbon.HIToolbox
import XCTest
@testable import scarcrux_textem

@MainActor
final class GlobalHotkeyTests: XCTestCase {
    func testCapturedShortcutRoundTripsThroughPreferences() throws {
        let suite = "textem-hotkey-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(GlobalHotkey.Shortcut.savedCopyCode(in: defaults), .copyCode)

        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.control, .command], timestamp: 0, windowNumber: 0, context: nil,
            characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: UInt16(kVK_ANSI_C)))
        let shortcut = try XCTUnwrap(GlobalHotkey.Shortcut.captured(from: event))
        XCTAssertEqual(shortcut.label, "⌃⌘C")
        shortcut.saveCopyCode(in: defaults)
        XCTAssertEqual(GlobalHotkey.Shortcut.savedCopyCode(in: defaults), shortcut)
    }

    func testExclusiveRegistrationRejectsDuplicateAndCanBeRetried() {
        _ = NSApplication.shared
        let shortcut = GlobalHotkey.Shortcut(key: UInt32(kVK_ANSI_Z),
            modifiers: UInt32(controlKey | shiftKey | optionKey | cmdKey), letter: "Z")
        let first = GlobalHotkey(shortcut: shortcut, onTrigger: {})
        let second = GlobalHotkey(shortcut: shortcut, onTrigger: {})
        defer { first.unregister(); second.unregister() }

        XCTAssertTrue(first.register())
        XCTAssertFalse(second.register())
        XCTAssertTrue(first.isRegistered)
        first.unregister()
        XCTAssertTrue(second.register())
    }
}
