import XCTest
@testable import scarcrux_textem

final class ConversationActivityTrackerTests: XCTestCase {
    private func row(_ id: String = "thread-1", fingerprint: String,
                     unread: Bool = true) -> ConversationSnapshot {
        ConversationSnapshot(
            id: id,
            sender: "Sender",
            snippet: fingerprint,
            fingerprint: fingerprint,
            isUnread: unread
        )
    }

    func testInitialSnapshotEstablishesBaselineWithoutNotifications() {
        var tracker = ConversationActivityTracker()
        XCTAssertEqual(tracker.update([row(fingerprint: "existing")]), [])
    }

    func testHydrationAfterInitialEmptySnapshotDoesNotNotify() {
        var tracker = ConversationActivityTracker()
        XCTAssertEqual(tracker.update([]), [])
        XCTAssertEqual(tracker.update([row(fingerprint: "existing")]), [])
        XCTAssertEqual(tracker.update([row(fingerprint: "new")]).map(\.fingerprint), ["new"])
    }

    func testChangedContentInAlreadyUnreadConversationNotifies() {
        var tracker = ConversationActivityTracker()
        _ = tracker.update([row(fingerprint: "first")])
        XCTAssertEqual(tracker.update([row(fingerprint: "second")]).map(\.fingerprint), ["second"])
    }

    func testMarkingSameContentUnreadDoesNotNotify() {
        var tracker = ConversationActivityTracker()
        _ = tracker.update([row(fingerprint: "same", unread: false)])
        XCTAssertEqual(tracker.update([row(fingerprint: "same", unread: true)]), [])
    }

    func testNewUnreadConversationAfterBaselineNotifies() {
        var tracker = ConversationActivityTracker()
        _ = tracker.update([row(fingerprint: "first")])
        let event = row("thread-2", fingerprint: "new")
        XCTAssertEqual(tracker.update([row(fingerprint: "first"), event]), [event])
    }

    func testRepeatedSnapshotIsDeduplicated() {
        var tracker = ConversationActivityTracker()
        let snapshot = [row(fingerprint: "same")]
        _ = tracker.update(snapshot)
        XCTAssertEqual(tracker.update(snapshot), [])
    }

    func testDuplicateDOMRowsDoNotCrashOrDoubleNotify() {
        var tracker = ConversationActivityTracker()
        _ = tracker.update([row(fingerprint: "baseline")])
        let duplicate = row("thread-2", fingerprint: "new")
        XCTAssertEqual(tracker.update([duplicate, duplicate]), [duplicate])
    }
}
