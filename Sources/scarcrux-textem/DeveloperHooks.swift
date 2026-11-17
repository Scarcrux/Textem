import Foundation

// Research hooks that can export session cookies, run a helper from an
// arbitrary path, or capture message traffic. They exist for development
// only: release builds (no DEBUG flag) always see them as unset, so setting
// an environment variable can't switch them on in a shipped Textem.
enum DeveloperHooks {
    static func value(_ key: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        #if DEBUG
        environment[key]
        #else
        nil
        #endif
    }

    static func isOn(_ key: String) -> Bool { value(key) == "1" }
}
