import AppKit
import UserNotifications

// Native notifications: click-to-focus, optional sender/preview, and inline
// reply. Sender/preview come from the JS bridge and are suppressed when
// `hideNotificationPreview` is set. Inline reply injects the typed text into
// the active conversation (best-effort DOM automation).
@MainActor
final class NotificationManager: NSObject {
    static let shared = NotificationManager()

    private static let categoryID = "textem.message"
    private static let replyActionID = "textem.reply"

    private var onOpen: (() -> Void)?
    private var onReply: ((String, String?) -> Void)?

    func configure(onOpen: @escaping () -> Void, onReply: @escaping (String, String?) -> Void) {
        self.onOpen = onOpen
        self.onReply = onReply
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // Category with a text field so replies work from the banner.
        let reply = UNTextInputNotificationAction(
            identifier: Self.replyActionID,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Reply…"
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [reply],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // A one-off informational banner (e.g. "Copied code 123456").
    func notifyInfo(_ body: String) {
        let content = UNMutableNotificationContent()
        content.title = "Textem"
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func notifyNewMessages(newCount: Int, sender: String?, snippet: String?, convId: String?) {
        let content = UNMutableNotificationContent()
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        // Pin the notification to its conversation so an inline reply lands in
        // THIS thread, not whichever one is unread by the time the user replies.
        if let convId, !convId.isEmpty { content.userInfo = ["convId": convId] }

        if Preferences.hideNotificationPreview {
            content.title = "Textem"
            content.body = newCount > 1 ? "\(newCount) new messages" : "New message"
        } else {
            let name = (sender?.isEmpty == false) ? sender! : "New message"
            content.title = name
            if let snippet, !snippet.isEmpty {
                content.body = snippet
            } else if newCount > 1 {
                content.body = "\(newCount) new messages"
            }
        }

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    // Show the banner even while Textem is frontmost-but-unfocused.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        // Inline reply: forward the typed text; otherwise focus the window.
        if let textResponse = response as? UNTextInputNotificationResponse {
            let text = textResponse.userText
            let convId = response.notification.request.content.userInfo["convId"] as? String
            completionHandler()
            Task { @MainActor in self.onReply?(text, convId) }
            return
        }
        completionHandler()
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            self.onOpen?()
        }
    }
}
