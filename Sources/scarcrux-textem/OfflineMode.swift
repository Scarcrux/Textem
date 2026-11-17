import Foundation

/// Explicit local browsing, independent of reachability and phone pairing.
enum OfflineMode {
    static let changed = Notification.Name("TextemOfflineModeChanged")
    // Tests use an isolated preference domain so the owner's saved offline
    // choice cannot change transport-test results, or be modified by tests.
    private final class Store: @unchecked Sendable {
        // UserDefaults synchronizes its own reads/writes; the wrapper shares
        // only that immutable reference, including with background transports.
        let defaults: UserDefaults
        init() {
            if NSClassFromString("XCTestCase") != nil {
                let name = "dev.textem.offline-tests.\(ProcessInfo.processInfo.processIdentifier)"
                defaults = UserDefaults(suiteName: name)!
                defaults.removePersistentDomain(forName: name)
            } else { defaults = .standard }
        }
    }
    private static let store = Store()
    static var preferences: UserDefaults { store.defaults }
    static var enabled: Bool { preferences.bool(forKey: "offlineMode") }
    @MainActor static func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        preferences.set(value, forKey: "offlineMode")
        NotificationCenter.default.post(name: changed, object: nil)
    }
    static func requireOnline() throws {
        guard !enabled else { throw Unavailable.offline }
    }
    enum Unavailable: Error, LocalizedError {
        case offline
        var errorDescription: String? { "Offline Mode is on. Choose Go Online to load live messages or connect to your phone. Saved content remains available." }
    }
}
