import AppKit
@preconcurrency import AuthenticationServices
import SwiftUI
import UserNotifications

enum MigrationFollowUp {
    static let copiedDataKey = "legacyIdentityCopiedData"
    private static let offeredKey = "legacyIdentityFollowUpOffered"

    static func isAvailable(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: copiedDataKey)
    }

    static func shouldPresent(in defaults: UserDefaults = .standard) -> Bool {
        isAvailable(in: defaults) && !defaults.bool(forKey: offeredKey)
    }

    static func markOffered(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: offeredKey)
    }
}

struct MigrationFollowUpSheet: View {
    let onDone: () -> Void
    let showAutoFill: Bool
    @State private var notifications: UNAuthorizationStatus?
    @State private var autoFillEnabled: Bool?
    @State private var launchAtLogin = false
    @State private var requestingNotifications = false
    @State private var loginNeedsAttention = false

    var body: some View {
        MigrationFollowUpView(
            notifications: notifications,
            showAutoFill: showAutoFill, autoFillEnabled: autoFillEnabled,
            launchAtLogin: Binding(get: { launchAtLogin }, set: { enabled in
                LoginItem.set(enabled)
                launchAtLogin = LoginItem.isEnabled
                loginNeedsAttention = launchAtLogin != enabled
            }),
            showPhoneTools: Preferences.showPhoneTools,
            requestingNotifications: requestingNotifications, loginNeedsAttention: loginNeedsAttention,
            onNotifications: notificationAction,
            onAutoFill: {
                if #available(macOS 26, *) {
                    openSettings("com.apple.Passwords-Settings.extension")
                } else {
                    openSettings("com.apple.Passwords")
                }
            },
            onDone: onDone
        )
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    @MainActor private func refresh() async {
        launchAtLogin = LoginItem.isEnabled
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if showAutoFill, #available(macOS 15, *) {
            autoFillEnabled = await withCheckedContinuation { continuation in
                ASCredentialIdentityStore.shared.getState { continuation.resume(returning: $0.isEnabled) }
            }
        }
    }

    @MainActor private func notificationAction() {
        switch notifications {
        case .notDetermined:
            guard !requestingNotifications else { return }
            requestingNotifications = true
            Task {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                await refresh()
                requestingNotifications = false
            }
        case .denied:
            openSettings("com.apple.Notifications-Settings.extension?id=com.scarcrux.textem")
        default:
            break
        }
    }

    @MainActor private func openSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:" + pane) else { return }
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/System Settings.app"),
                                               configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

struct MigrationFollowUpView: View {
    let notifications: UNAuthorizationStatus?
    let showAutoFill: Bool
    let autoFillEnabled: Bool?
    @Binding var launchAtLogin: Bool
    let showPhoneTools: Bool
    var requestingNotifications = false
    var loginNeedsAttention = false
    let onNotifications: () -> Void
    let onAutoFill: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("A few settings after updating Textem").font(.title2.bold())
                Text("Textem moved your existing data. macOS treats this version as a new app, so you can turn these features back on if you use them.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                row("Notifications", icon: "bell", detail: notificationDetail) {
                    if notifications == .notDetermined {
                        Button("Allow Notifications", action: onNotifications).disabled(requestingNotifications)
                    } else if notifications == .denied {
                        Button("Open Notifications", action: onNotifications)
                    }
                }
                if showAutoFill {
                    Divider()
                    row("Textem Codes", icon: "key", detail: autoFillDetail) {
                        Button("Open AutoFill Settings", action: onAutoFill)
                    }
                }
                Divider()
                row("Launch at Login", icon: "power", detail: loginNeedsAttention
                    ? "Check General → Login Items & Extensions in System Settings."
                    : "Open Textem when you log in to this Mac.") {
                    Toggle("Launch at Login", isOn: $launchAtLogin).labelsHidden().toggleStyle(.switch)
                }
                if showPhoneTools {
                    Divider()
                    row("Phone Companion", icon: "iphone", detail: "To reconnect, re-import the connection file from the phone connection panel.") {
                        EmptyView()
                    }
                }
            }
            HStack {
                Text("Find this again in Help → After Updating.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 550)
    }

    private var notificationDetail: String {
        switch notifications {
        case .notDetermined: "Permission hasn’t been requested."
        case .denied: "Notifications are off in System Settings."
        case .authorized: "Notifications are allowed."
        case .provisional: "Notifications can be delivered quietly."
        case .none: "Checking permission…"
        default: "Check Notifications in System Settings."
        }
    }

    private var autoFillDetail: String {
        switch autoFillEnabled {
        case true?: "Enabled in macOS. To offer codes, also turn on AutoFill in Textem’s Verification Codes settings."
        case false?: "Enable Textem Codes in System Settings, then turn on AutoFill in Textem’s Verification Codes settings."
        case nil: "Checking AutoFill in macOS…"
        }
    }

    private func row<Control: View>(_ title: String, icon: String, detail: String,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control().fixedSize()
        }
    }
}
