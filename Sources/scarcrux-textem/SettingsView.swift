import SwiftUI

// The Preferences UI. Uses @AppStorage bound to the same UserDefaults keys
// as `Preferences`, plus custom bindings for the toggles that have side
// effects (login item registration, activation policy). Custom bindings
// avoid the macOS 13-vs-14 `onChange` signature split.
struct SettingsView: View {
    @AppStorage("startHidden") private var startHidden = false
    @AppStorage("quitOnClose") private var quitOnClose = false
    @AppStorage("menuBarOnly") private var menuBarOnly = false
    @AppStorage("notificationsMuted") private var notificationsMuted = false
    @AppStorage("hideNotificationPreview") private var hideNotificationPreview = false
    @AppStorage("blurMessages") private var blurMessages = false
    @AppStorage("hideAvatars") private var hideAvatars = false
    @State private var launchAtLogin = LoginItem.isEnabled

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
                Toggle("Start hidden (menu bar only at launch)", isOn: notifying($startHidden))
                Toggle("Menu bar only (hide Dock icon)", isOn: Binding(
                    get: { menuBarOnly },
                    set: { newValue in
                        menuBarOnly = newValue
                        NSApp.setActivationPolicy(newValue ? .accessory : .regular)
                        settingsChanged()
                    }
                ))
                Toggle("Quit when window is closed", isOn: notifying($quitOnClose))
            }

            Section("Notifications") {
                Toggle("Mute notifications", isOn: notifying($notificationsMuted))
                Toggle("Hide sender & preview in notifications", isOn: notifying($hideNotificationPreview))
                Text("The dock badge still updates while muted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Toggle("Blur message previews (clears on hover)", isOn: Binding(
                    get: { blurMessages },
                    set: { blurMessages = $0; privacyChanged() }
                ))
                Toggle("Hide avatars", isOn: Binding(
                    get: { hideAvatars },
                    set: { hideAvatars = $0; privacyChanged() }
                ))
                Text("Display-only — these hide content from view but don't change what's sent (read receipts are server-side).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 470)
    }
}
