import AppKit
import LocalAuthentication
import SwiftUI
import UserNotifications
import WebKit
import XCTest
@testable import scarcrux_textem

@MainActor
final class AppLockTests: XCTestCase {
    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "textem-app-lock-tests-" + UUID().uuidString
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    func testOptInIsAuthenticatedAndRelaunchStartsLocked() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let denied = AppLock(defaults: defaults, authenticate: { _, _, _ in false })
        XCTAssertFalse(denied.isLocked)
        await denied.setEnabled(true)
        XCTAssertFalse(denied.isEnabled)
        let lock = AppLock(defaults: defaults, authenticate: { _, _, _ in true })
        await lock.setEnabled(true)
        XCTAssertTrue(lock.isEnabled)
        let relaunched = AppLock(defaults: defaults, authenticate: { _, _, _ in false })
        XCTAssertTrue(relaunched.isLocked)
        await relaunched.setEnabled(false)
        let unlocked = await relaunched.unlock()
        XCTAssertFalse(unlocked)
        XCTAssertTrue(relaunched.isLocked)
        XCTAssertTrue(relaunched.isEnabled)
    }

    func testSleepInvalidatesAnUnlockAlreadyInFlight() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "requireAppUnlock")
        let started = expectation(description: "authentication started")
        var answer: CheckedContinuation<Bool, Never>?
        let lock = AppLock(defaults: defaults, authenticate: { _, _, _ in
            await withCheckedContinuation { continuation in
                answer = continuation
                started.fulfill()
            }
        })
        let attempt = Task { await lock.unlock() }
        await fulfillment(of: [started], timeout: 2)
        lock.lock()
        answer?.resume(returning: true)
        let unlocked = await attempt.value
        XCTAssertFalse(unlocked)
        XCTAssertTrue(lock.isLocked)
    }

    func testAwayTimerLocksOnlyWhenEnabled() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let lock = AppLock(defaults: defaults, awayDelay: .milliseconds(30), authenticate: { _, _, _ in true })
        await lock.setEnabled(true)
        lock.setAway(true)
        XCTAssertFalse(lock.isLocked)
        let locked = expectation(description: "away timer locked")
        lock.onLockChanged = { locked.fulfill() }
        lock.lockWhenAway = true
        await fulfillment(of: [locked], timeout: 2)
        XCTAssertTrue(lock.isLocked)
    }

    func testImmediateAwayLockIsOptInAndPersists() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let lock = AppLock(defaults: defaults, authenticate: { _, _, _ in true })
        await lock.setEnabled(true)
        lock.setAway(true)
        XCTAssertFalse(lock.isLocked)
        lock.setAway(false)
        lock.lockOnFocusLoss = true

        let relaunched = AppLock(defaults: defaults, authenticate: { _, _, _ in true })
        XCTAssertTrue(relaunched.lockOnFocusLoss)
        let unlocked = await relaunched.unlock()
        XCTAssertTrue(unlocked)
        relaunched.setAway(true)
        XCTAssertTrue(relaunched.isLocked)
        relaunched.setAway(false)
        XCTAssertTrue(relaunched.isLocked, "Focus returning must not unlock Textem")
    }

    func testFocusPromptsOnceAndRemainsLockedAfterCancellation() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "requireAppUnlock")
        var attempts = 0
        var dialogTakesFocus: (() -> Void)?
        let lock = AppLock(defaults: defaults, touchIDStatus: { .available }, authenticate: { _, _, _ in
            attempts += 1
            dialogTakesFocus?()
            return attempts == 2
        })
        lock.setAway(true)
        await lock.promptToUnlockOnFocus()
        XCTAssertEqual(attempts, 0)
        lock.setAway(false)
        dialogTakesFocus = {
            lock.setAway(true)
            lock.setAway(false)
        }
        await lock.promptToUnlockOnFocus()
        dialogTakesFocus = nil
        await lock.promptToUnlockOnFocus()
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(lock.isLocked)

        lock.setAway(true)
        lock.setAway(false)
        await lock.promptToUnlockOnFocus()
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(lock.isLocked)
    }

    func testFailedAutomaticTouchIDLeavesPasswordAsAnExplicitChoice() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "requireAppUnlock")
        var policies: [LAPolicy] = []
        let lock = AppLock(defaults: defaults, touchIDStatus: { .available }, authenticate: { _, policy, _ in
            policies.append(policy)
            return policy == .deviceOwnerAuthentication
        })
        await lock.promptToUnlockOnFocus()
        XCTAssertTrue(lock.isLocked)
        XCTAssertEqual(policies, [.deviceOwnerAuthenticationWithBiometrics])
        let didUnlock = await lock.unlock()
        XCTAssertTrue(didUnlock)
        XCTAssertFalse(lock.isLocked)
        XCTAssertEqual(policies, [.deviceOwnerAuthenticationWithBiometrics, .deviceOwnerAuthentication])
    }

    func testFocusDoesNotPromptWhenTouchIDIsUnavailable() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "requireAppUnlock")
        let lock = AppLock(defaults: defaults, touchIDStatus: { .unavailable }, authenticate: { _, _, _ in
            XCTFail("Focus should not prompt for a password")
            return false
        })
        await lock.promptToUnlockOnFocus()
        XCTAssertTrue(lock.isLocked)
    }

    func testFocusReportsTouchIDLockoutWithoutPrompting() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "requireAppUnlock")
        let lock = AppLock(defaults: defaults, touchIDStatus: { .lockedOut }, authenticate: { _, _, _ in
            XCTFail("Touch ID lockout should leave password entry to the user")
            return false
        })
        await lock.promptToUnlockOnFocus()
        XCTAssertTrue(lock.touchIDLockedOut)
        XCTAssertTrue(lock.isLocked)
    }

    func testNotificationActionRequiresAnActualUnlock() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "requireAppUnlock")
        let lock = AppLock(defaults: defaults, authenticate: { _, _, _ in true })
        let declined = await lock.authorizeAction { false }
        XCTAssertFalse(declined)
        let fakeSuccess = await lock.authorizeAction { true }
        XCTAssertFalse(fakeSuccess)
        let unlocked = await lock.authorizeAction { await lock.unlock() }
        XCTAssertTrue(unlocked)
    }

    func testLockDistinguishesAnUnsentReplyFromAnUnconfirmedSend() {
        XCTAssertNil(WebViewController.interruptedReplyNotice(active: false, dispatched: true, queued: false))
        XCTAssertEqual(WebViewController.interruptedReplyNotice(active: true, dispatched: false, queued: false),
                       "Textem locked before sending your reply.")
        XCTAssertEqual(WebViewController.interruptedReplyNotice(active: true, dispatched: true, queued: true),
                       "Reply status unknown. Check the conversation before resending. Other queued replies were not sent.")
    }

    func testLockedTextemNotifiesEvenWhenFrontmost() {
        XCTAssertFalse(WebViewController.shouldNotify(appActive: true, locked: false, muted: false))
        XCTAssertTrue(WebViewController.shouldNotify(appActive: true, locked: true, muted: false))
        XCTAssertTrue(WebViewController.shouldNotify(appActive: false, locked: false, muted: false))
        XCTAssertFalse(WebViewController.shouldNotify(appActive: false, locked: true, muted: true))
    }

    func testLockedNotificationRemovesPreviewAndCodeSignal() {
        func redacted(_ category: String) -> UNMutableNotificationContent {
            let content = UNMutableNotificationContent()
            content.title = "Example sender"
            content.subtitle = "Example thread"
            content.body = "Example code 123456"
            content.categoryIdentifier = category
            NotificationManager.redactForAppLock(content)
            return content
        }
        let message = redacted("textem.message")
        XCTAssertEqual(message.title, "Textem")
        XCTAssertEqual(message.subtitle, "")
        XCTAssertEqual(message.body, "Unlock Textem to see details.")
        // Reply survives (it asks for unlock before sending)...
        XCTAssertEqual(message.categoryIdentifier, "textem.message")
        // ...but a message with a code must look exactly like any other message,
        // and a code-only notification loses its Copy Code action entirely.
        XCTAssertEqual(redacted("textem.message.code").categoryIdentifier, "textem.message")
        XCTAssertEqual(redacted("textem.code").categoryIdentifier, "")
        XCTAssertEqual(redacted("textem.message.code").body, message.body)
    }

    // Regression (owner test 2026-11-24): a text sent while locked was first
    // seen one second after unlocking, because the page had been taken out of
    // the window and WebKit suspended it. The page must stay in the window,
    // hidden under an opaque cover, from a cold locked launch onward.
    func testLockedWindowKeepsMessagesRunningHiddenUnderOpaqueCover() async throws {
        _ = NSApplication.shared
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "requireAppUnlock")
        let lock = AppLock(defaults: defaults, touchIDStatus: { .lockedOut }, authenticate: { _, _, _ in true })
        let controller = MainWindowController(account: Account(name: "Example", storeIdentifier: nil),
            storeForAccount: { _ in WKWebsiteDataStore.nonPersistent() }, initialURL: URL(string: "about:blank"),
            appLock: lock)
        let window = try XCTUnwrap(controller.window)
        defer { window.orderOut(nil); controller.webViewController.teardown() }
        lock.onLockChanged = { [weak controller] in controller?.refreshLockPresentation() }
        let messages = controller.webViewController.view
        XCTAssertTrue(messages.window === window, "Cold locked launch must keep Messages running in the window")
        XCTAssertTrue(messages.isHidden)
        XCTAssertTrue(window.contentViewController is LockedContentController)
        let unlocked = await lock.unlock()
        XCTAssertTrue(unlocked)
        XCTAssertTrue(window.contentViewController === controller.webViewController)
        XCTAssertFalse(messages.isHidden)
        let unlockedSize = window.frame.size
        lock.lockOnFocusLoss = true
        lock.setAway(true)
        XCTAssertEqual(window.frame.size, unlockedSize)
        XCTAssertTrue(messages.window === window, "Locking must not take Messages out of the window")
        XCTAssertTrue(messages.isHidden && messages.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(window.title, "Textem — Locked")
        lock.setAway(false)
        await lock.promptToUnlockOnFocus()
        XCTAssertTrue(lock.touchIDLockedOut)
        let locked = try XCTUnwrap(window.contentViewController as? LockedContentController)
        let cover = try XCTUnwrap(locked.coverController as? NSHostingController<AppLockView>)
        XCTAssertTrue(cover.view.superview?.subviews.last === cover.view, "The cover must be on top")
        if let destination = ProcessInfo.processInfo.environment["TEXTEM_APP_LOCK_SNAPSHOTS"] {
            let folder = URL(fileURLWithPath: destination)
            for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                cover.view.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let bitmap = try XCTUnwrap(cover.view.bitmapImageRepForCachingDisplay(in: cover.view.bounds))
                cover.view.cacheDisplay(in: cover.view.bounds, to: bitmap)
                XCTAssertGreaterThan(bitmap.pixelsWide, 300)
                let corner = try XCTUnwrap(bitmap.colorAt(x: 4, y: 4)?.usingColorSpace(.deviceRGB))
                XCTAssertEqual(corner.alphaComponent, 1, accuracy: 0.01)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: folder.appendingPathComponent("app-lock-\(mode).png"))
            }
        }
    }
}
