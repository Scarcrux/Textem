import Foundation

// One-time carry-over from Textem's original bundle identifier.
//
// Textem was first released under a different bundle identifier
// (`legacyIdentifier` below); it is now `com.scarcrux.textem`. macOS keys an app's preferences and its WebKit
// sessions by bundle identifier, so without this an update would look like a
// fresh install: settings gone, and every Google account signed out and
// unpaired. On the first launch under the new identifier this COPIES (never
// moves) the old preferences and WebKit session data, so the old app keeps
// working if someone reinstalls it. It runs before any web view exists.
//
// Not carried over (macOS ties these to the app itself): notification
// permission, the Textem Codes AutoFill enablement, launch at login, and
// Keychain items such as a paired phone companion.
enum LegacyIdentityMigration {
    // The original identifier, needed to find old data. Assembled from parts so
    // a whole-history rename of the identifier cannot rewrite it too.
    static let legacyIdentifier = ["ai", "scarpelli", "textem"].joined(separator: ".")
    static let currentIdentifier = "com.scarcrux.textem"
    static let doneKey = "migratedFromLegacyIdentifier"

    struct Report: Equatable {
        var preferences = 0
        var copied: [String] = []
        var skipped = false
    }

    @discardableResult
    static func runIfNeeded(library: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0],
                            bundleIdentifier: String? = Bundle.main.bundleIdentifier,
                            defaults: UserDefaults = .standard,
                            legacyPreferences: () -> [String: Any] = Self.legacyPreferences) -> Report {
        var report = Report()
        guard bundleIdentifier == currentIdentifier, !defaults.bool(forKey: doneKey) else {
            report.skipped = true; return report
        }
        // Preferences: copy each old key the new app doesn't already have.
        for (key, value) in legacyPreferences() where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key); report.preferences += 1
        }
        // WebKit sessions and cookies. Copy only into places that don't exist
        // yet, so a person who already signed in under the new app keeps that.
        let fm = FileManager.default
        for relative in ["WebKit/\(legacyIdentifier)", "HTTPStorages/\(legacyIdentifier)",
                         "HTTPStorages/\(legacyIdentifier).binarycookies"] {
            let source = library.appendingPathComponent(relative)
            let target = library.appendingPathComponent(relative.replacingOccurrences(of: legacyIdentifier, with: currentIdentifier))
            guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: target.path) else { continue }
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: target)
                report.copied.append(relative)
            } catch {
                NSLog("[Textem] legacy identity migration could not copy %@: %@", relative, error.localizedDescription)
            }
        }
        if report.preferences > 0 || !report.copied.isEmpty {
            defaults.set(true, forKey: MigrationFollowUp.copiedDataKey)
        }
        defaults.set(true, forKey: doneKey)
        NSLog("[Textem] legacy identity migration: %d preferences, %d data folders", report.preferences, report.copied.count)
        return report
    }

    static func legacyPreferences() -> [String: Any] {
        let domain = legacyIdentifier as CFString
        guard let keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String],
              let values = CFPreferencesCopyMultiple(keys as CFArray, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any]
        else { return [:] }
        return values
    }
}
