import AppKit
import UserNotifications

// Native notifications + click-to-focus. Kept deliberately content-less for
// now (no sender/preview): we derive "a message arrived" from the unread
// count rising, which needs no DOM scraping and leaks nothing into the
// banner. Sender/preview can come later via an opt-in JS bridge.
@MainActor
final class NotificationManager: NSObject {
    static let shared = NotificationManager()

    private var onOpen: (() -> Void)?

    func configure(onOpen: @escaping () -> Void) {
        self.onOpen = onOpen
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func notifyNewMessages(newCount: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Textem"
        content.body = newCount > 1 ? "\(newCount) new messages" : "New message"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
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

    // Click the banner -> bring Textem forward and focus the window.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            self.onOpen?()
        }
    }
}
