import SwiftUI

// The Preferences UI. Uses @AppStorage bound to the same UserDefaults keys
// as `Preferences`, plus custom bindings for the toggles that have side
// effects (login item registration, activation policy). Custom bindings
// avoid the macOS 13-vs-14 `onChange` signature split.
struct SettingsView: View {
    @ObservedObject private var appLock: AppLock
    @AppStorage("startHidden") private var startHidden = false
    @AppStorage("quitOnClose") private var quitOnClose = false
    @AppStorage("menuBarOnly") private var menuBarOnly = false
    @AppStorage("notificationsMuted") private var notificationsMuted = false
    @AppStorage("hideNotificationPreview") private var hideNotificationPreview = false
    @AppStorage("blurMessages") private var blurMessages = false
    @AppStorage("hideAvatars") private var hideAvatars = false
    @AppStorage("globalCopyCode") private var globalCopyCode = false
    @State private var shortcutUnavailable = false
    @State private var codeShortcut = GlobalHotkey.Shortcut.savedCopyCode()
    @State private var choosingCodeShortcut = false
    @AppStorage("copyCodeNotifications") private var copyCodeNotifications = true
    @State private var showPhoneTools = Preferences.showPhoneTools
    @State private var launchAtLogin = LoginItem.isEnabled
    @StateObject private var nativeCodes: NativeAutoFillCoordinator
    @StateObject private var updates: AppUpdates

    init(nativeCodes: NativeAutoFillCoordinator = .shared, updates: AppUpdates = .shared,
         appLock: AppLock = .shared) {
        self.appLock = appLock
        _nativeCodes = StateObject(wrappedValue: nativeCodes)
        _updates = StateObject(wrappedValue: updates)
    }

    // Notify the live web view to re-apply privacy CSS after a toggle.
    private func privacyChanged() {
        NotificationCenter.default.post(name: Preferences.privacyChanged, object: nil)
        settingsChanged()
    }

    private func settingsChanged() {
        NotificationCenter.default.post(name: Preferences.settingsChanged, object: nil)
    }

    private func notifying(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { binding.wrappedValue },
            set: { binding.wrappedValue = $0; settingsChanged() }
        )
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        LoginItem.set(newValue)
                        launchAtLogin = LoginItem.isEnabled
                        settingsChanged()
                    }
                ))
                Toggle(isOn: notifying($startHidden)) {
                    row("Start hidden", "Launch into the menu bar without opening a window.")
                }
                Toggle(isOn: Binding(
                    get: { menuBarOnly },
                    set: { newValue in
                        menuBarOnly = newValue
                        NSApp.setActivationPolicy(newValue ? .accessory : .regular)
                        settingsChanged()
                    }
                )) {
                    row("Menu bar only", "Hide the Dock icon. Textem stays in the menu bar.")
                }
                Toggle("Quit when the window is closed", isOn: notifying($quitOnClose))
            }

            Section {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) }
                )).disabled(!updates.started)
                Button("Check for Updates…") { updates.check() }.disabled(!updates.canCheck)
            } header: {
                Text("Updates")
            } footer: {
                footer(updates.status)
            }

            Section {
                Toggle("Mute notifications", isOn: notifying($notificationsMuted))
                Toggle("Hide sender and message preview", isOn: notifying($hideNotificationPreview))
            } header: {
                Text("Notifications")
            } footer: {
                footer("The Dock badge still updates while notifications are muted.")
            }

            Section {
                Toggle(isOn: notifying($copyCodeNotifications)) {
                    row("Copy Code button in notifications",
                        "When a text with a verification code arrives, its notification can copy the code.")
                }
                Toggle(isOn: Binding(
                    get: { globalCopyCode },
                    set: { enabled in
                        let registered = (NSApp.delegate as? AppDelegate)?.configureGlobalCodeShortcut(enabled: enabled) ?? false
                        shortcutUnavailable = enabled && !registered
                        if registered { globalCopyCode = enabled }
                    }
                )) {
                    row("Global Copy Latest Code shortcut",
                        "Press \(codeShortcut.label) in any app to copy a code received in the active account in the last 3 minutes.")
                }
                .onAppear {
                    if globalCopyCode {
                        shortcutUnavailable = (NSApp.delegate as? AppDelegate)?.isGlobalCodeShortcutRegistered != true
                    }
                }
                Button("Change Shortcut…") { choosingCodeShortcut = true }
                    .sheet(isPresented: $choosingCodeShortcut) {
                        CodeShortcutPicker { candidate in
                            guard (NSApp.delegate as? AppDelegate)?.changeGlobalCodeShortcut(to: candidate) == true
                            else { return false }
                            codeShortcut = candidate
                            shortcutUnavailable = false
                            return true
                        }
                    }
                if shortcutUnavailable {
                    Text("\(codeShortcut.label) is unavailable. It may already be assigned to another app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(isOn: Binding(
                    get: { nativeCodes.enabled }, set: { value in Task { await nativeCodes.setEnabled(value) } }
                )) {
                    row("AutoFill verification codes (Experimental)",
                        "Offer codes from your texts in Safari and other apps, through Textem Codes. Not yet confirmed working in every app.")
                }.disabled(!nativeCodes.available).accessibilityIdentifier("native-code-autofill-toggle")
                Button("Delete native codes and source links", role: .destructive) {
                    Task { await nativeCodes.setEnabled(false) }
                }.disabled(!nativeCodes.available)
            } header: {
                Text("Verification Codes")
            } footer: {
                footer(nativeCodes.status).accessibilityIdentifier("native-code-autofill-status")
            }

            Section {
                Toggle("Require Touch ID or your Mac password to open Textem", isOn: Binding(
                    get: { appLock.isEnabled },
                    set: { enabled in Task { await appLock.setEnabled(enabled) } }
                )).disabled(appLock.isAuthenticating)
                if appLock.isEnabled {
                    Toggle(isOn: $appLock.lockOnFocusLoss) {
                        row("Lock immediately when I switch away",
                            "Also locks when you minimize or close the Textem window.")
                    }
                    Toggle("Lock after 5 minutes of inactivity in Textem", isOn: $appLock.lockWhenAway)
                }
                if appLock.authenticationFailed {
                    Text("macOS didn’t confirm the change. Try again.").font(.caption)
                }
                Text("The lock protects Textem’s window. Your Google session and saved files still rely on your Mac login and FileVault.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(isOn: Binding(
                    get: { blurMessages },
                    set: { blurMessages = $0; privacyChanged() }
                )) {
                    row("Blur message previews", "Hover over a preview to read it.")
                }
                Toggle("Hide avatars", isOn: Binding(
                    get: { hideAvatars },
                    set: { hideAvatars = $0; privacyChanged() }
                ))
            } header: {
                Text("Privacy")
            } footer: {
                footer("These only change what is shown on this Mac. Read receipts and what you send are unaffected.")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { showPhoneTools },
                    set: { Preferences.showPhoneTools = $0; showPhoneTools = $0; settingsChanged() }
                )) {
                    row("Show phone companion tools",
                        "Adds the Phone menu for the experimental Android companion. Needs Android developer tools.")
                }
            } header: {
                Text("Advanced")
            }
        }
        .formStyle(.grouped)
        // The extra update controls make the intrinsic form taller than a
        // laptop's usable screen. Bound the window; grouped Form scrolls.
        .frame(width: 480, height: min(760, max(400, (NSScreen.main?.visibleFrame.height ?? 900) - 80)))
    }

    // A setting whose name alone doesn't say what it does gets one line of
    // explanation under it, instead of a parenthetical crammed into the label.
    private func row(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func footer(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
