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
    @StateObject private var nativeCodes: NativeAutoFillCoordinator

    init(nativeCodes: NativeAutoFillCoordinator = .shared) {
        _nativeCodes = StateObject(wrappedValue: nativeCodes)
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
                Toggle("Mute notifications", isOn: notifying($notificationsMuted))
                Toggle("Hide sender and message preview", isOn: notifying($hideNotificationPreview))
            } header: {
                Text("Notifications")
            } footer: {
                footer("The Dock badge still updates while notifications are muted.")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { nativeCodes.enabled }, set: { value in Task { await nativeCodes.setEnabled(value) } }
                )) {
                    row("AutoFill verification codes",
                        "Offer fresh codes from your texts in other apps, through Textem Codes.")
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
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
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
