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
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        LoginItem.set(newValue)
                        launchAtLogin = LoginItem.isEnabled
                    }
                ))
                Toggle("Start hidden (menu bar only at launch)", isOn: $startHidden)
                Toggle("Menu bar only (hide Dock icon)", isOn: Binding(
                    get: { menuBarOnly },
                    set: { newValue in
                        menuBarOnly = newValue
                        NSApp.setActivationPolicy(newValue ? .accessory : .regular)
                    }
                ))
                Toggle("Quit when window is closed", isOn: $quitOnClose)
            }

            Section("Notifications") {
                Toggle("Mute notifications", isOn: $notificationsMuted)
                Text("The dock badge still updates while muted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 320)
    }
}
