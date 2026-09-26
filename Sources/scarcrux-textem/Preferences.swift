import Foundation

// UserDefaults-backed app preferences. Kept as a tiny namespace rather than
// an observable object since the current surface (menu-bar toggles) reads
// them on demand.
@MainActor
enum Preferences {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let startHidden = "startHidden"
        static let quitOnClose = "quitOnClose"
        static let menuBarOnly = "menuBarOnly"
        static let notificationsMuted = "notificationsMuted"
        static let zoom = "zoom"
        static let hasSeenOnboarding = "hasSeenOnboarding"
        static let hideNotificationPreview = "hideNotificationPreview"
        static let blurMessages = "blurMessages"
        static let hideAvatars = "hideAvatars"
    }

    // Posted when a privacy toggle changes so the live web view re-applies CSS.
    static let privacyChanged = Notification.Name("TextemPrivacyChanged")
    // Posted when Settings changes a value mirrored in the menu-bar menu.
    static let settingsChanged = Notification.Name("TextemSettingsChanged")

    // Notifications show only "New message" instead of sender + snippet.
    static var hideNotificationPreview: Bool {
        get { defaults.bool(forKey: Key.hideNotificationPreview) }
        set { defaults.set(newValue, forKey: Key.hideNotificationPreview) }
    }

    // Privacy: blur message text/snippets (clears on hover) so shoulder-surfers
    // can't read them. Display-only — does not affect what's sent.
    static var blurMessages: Bool {
        get { defaults.bool(forKey: Key.blurMessages) }
        set { defaults.set(newValue, forKey: Key.blurMessages) }
    }

    // Privacy: hide contact avatars.
    static var hideAvatars: Bool {
        get { defaults.bool(forKey: Key.hideAvatars) }
        set { defaults.set(newValue, forKey: Key.hideAvatars) }
    }

    // Whether the first-run sign-in guidance has been shown.
    static var hasSeenOnboarding: Bool {
        get { defaults.bool(forKey: Key.hasSeenOnboarding) }
        set { defaults.set(newValue, forKey: Key.hasSeenOnboarding) }
    }

    // Page zoom factor (1.0 = 100%), clamped 0.5–2.0 by callers.
    static var zoom: Double {
        get { let v = defaults.double(forKey: Key.zoom); return v == 0 ? 1.0 : v }
        set { defaults.set(newValue, forKey: Key.zoom) }
    }

    // Launch to the menu bar/background instead of showing the window.
    static var startHidden: Bool {
        get { defaults.bool(forKey: Key.startHidden) }
        set { defaults.set(newValue, forKey: Key.startHidden) }
    }

    // Quit the app when the main window is closed (default: keep running).
    static var quitOnClose: Bool {
        get { defaults.bool(forKey: Key.quitOnClose) }
        set { defaults.set(newValue, forKey: Key.quitOnClose) }
    }

    // Hide the Dock icon and run from the menu bar only (.accessory policy).
    static var menuBarOnly: Bool {
        get { defaults.bool(forKey: Key.menuBarOnly) }
        set { defaults.set(newValue, forKey: Key.menuBarOnly) }
    }

    // Suppress native notification banners (badge still updates).
    static var notificationsMuted: Bool {
        get { defaults.bool(forKey: Key.notificationsMuted) }
        set { defaults.set(newValue, forKey: Key.notificationsMuted) }
    }
}
