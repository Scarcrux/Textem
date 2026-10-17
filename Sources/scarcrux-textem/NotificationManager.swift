import AppKit
import UserNotifications

// Native notifications carry both account and conversation identity. Actions
// can therefore restore the exact originating context instead of operating on
// whichever account happens to be active later.
@MainActor
final class NotificationManager: NSObject {
    static let shared = NotificationManager()

    nonisolated private static let messageCategoryID = "textem.message"
    nonisolated private static let replyActionID = "textem.reply"
    nonisolated private static let accountKey = "accountID"
    nonisolated private static let conversationKey = "conversationID"

    private var onOpen: ((UUID?, String?) -> Void)?
    private var onReply: ((String, UUID?, String?) -> Void)?

    func configure(onOpen: @escaping (UUID?, String?) -> Void,
                   onReply: @escaping (String, UUID?, String?) -> Void) {
        self.onOpen = onOpen
        self.onReply = onReply
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let reply = UNTextInputNotificationAction(
            identifier: Self.replyActionID,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Reply…"
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.messageCategoryID,
                actions: [reply],
                intentIdentifiers: [],
                options: []
            ),
        ])
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, error in
            Task { @MainActor in
                NotificationDiagnostics.record("authorization", values: [
                    "granted": granted ? 1 : 0, "error": (error as NSError?)?.code ?? 0
                ])
                self.logSettings()
            }
            if let error {
                NSLog("[Textem] notification authorization failed: %@", error.localizedDescription)
            } else if !granted {
                NSLog("[Textem] notification authorization was not granted")
            }
        }
    }

    private func logSettings() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let values = [
                "authorization": settings.authorizationStatus.rawValue,
                "alerts": settings.alertSetting.rawValue,
                "style": settings.alertStyle.rawValue,
                "sound": settings.soundSetting.rawValue,
                "notificationCenter": settings.notificationCenterSetting.rawValue
            ]
            Task { @MainActor in
                NotificationDiagnostics.record("settings", values: values)
            }
        }
    }

    // Uses the same add/completion path as real messages, independent of DOM
    // changes. No reply action, so a probe cannot send to a real conversation.
    func sendTestNotification() {
        logSettings()
        let content = UNMutableNotificationContent()
        content.title = "Textem notification test"
        content.body = "Textem can request notifications from macOS."
        content.sound = .default
        add(content, kind: "test")
    }

    func notifyInfo(_ body: String) {
        let content = UNMutableNotificationContent()
        content.title = "Textem"
        content.body = body
        add(content, kind: "info")
    }

    func notifyNewMessage(sender: String, snippet: String,
                          accountID: UUID, conversationID: String) {
        let content = UNMutableNotificationContent()
        content.sound = .default
        content.categoryIdentifier = Self.messageCategoryID
        content.threadIdentifier = "\(accountID.uuidString):\(conversationID)"
        content.userInfo = [
            Self.accountKey: accountID.uuidString,
            Self.conversationKey: conversationID,
        ]

        if Preferences.hideNotificationPreview {
            content.title = "Textem"
            content.body = "New message"
        } else {
            content.title = sender.isEmpty ? "New message" : sender
            content.body = snippet.isEmpty ? "New message" : snippet
        }
        add(content, kind: "message")
    }

    private func add(_ content: UNMutableNotificationContent, kind: String) {
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        let requestID = request.identifier
        NotificationDiagnostics.record("request_" + kind)
        UNUserNotificationCenter.current().add(request) { error in
            Task { @MainActor in
                NotificationDiagnostics.record(
                    error == nil ? "accepted_" + kind : "rejected_" + kind,
                    values: ["error": (error as NSError?)?.code ?? 0])
                if kind == "test", error == nil {
                    try? await Task.sleep(for: .seconds(3))
                    let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
                    NotificationDiagnostics.record("delivered_test", values: [
                        "found": delivered.contains { $0.request.identifier == requestID } ? 1 : 0
                    ])
                }
            }
            if let error {
                NSLog("[Textem] notification delivery failed: %@", error.localizedDescription)
            }
        }
    }

    private nonisolated static func route(
        from response: UNNotificationResponse
    ) -> (UUID?, String?) {
        let info = response.notification.request.content.userInfo
        let accountID = (info[accountKey] as? String).flatMap(UUID.init(uuidString:))
        let conversationID = info[conversationKey] as? String
        return (accountID, conversationID)
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Task { @MainActor in NotificationDiagnostics.record("foreground_presentation") }
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let (accountID, conversationID) = Self.route(from: response)
        if response.actionIdentifier == Self.replyActionID,
           let textResponse = response as? UNTextInputNotificationResponse {
            let text = textResponse.userText
            completionHandler()
            Task { @MainActor in
                self.onReply?(text, accountID, conversationID)
            }
            return
        }

        completionHandler()
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            self.onOpen?(accountID, conversationID)
        }
    }
}
