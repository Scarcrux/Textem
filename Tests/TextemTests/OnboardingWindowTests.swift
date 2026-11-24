import AppKit
import XCTest
@testable import scarcrux_textem

// Closing the sign-in guide counts as having seen it, exactly once; closing it
// because Textem locked does not, so the guide returns after unlocking.
@MainActor
final class OnboardingWindowTests: XCTestCase {
    func testClosingCountsAsSeenOnce() {
        _ = NSApplication.shared
        var finished = 0
        let controller = OnboardingWindowController(onDone: { finished += 1 })
        XCTAssertTrue(controller.window?.styleMask.contains(.closable) == true)
        controller.close()
        controller.close()
        XCTAssertEqual(finished, 1)
    }

    func testLockDismissalDoesNotCountAsSeen() {
        _ = NSApplication.shared
        var finished = 0
        let controller = OnboardingWindowController(onDone: { finished += 1 })
        controller.dismissForLock()
        XCTAssertEqual(finished, 0)
    }
}
