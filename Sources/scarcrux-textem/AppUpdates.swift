import AppKit
import Sparkle

struct AppUpdateConfiguration: Equatable {
    let feed: URL
    let publicKey: String
    enum Invalid: String, LocalizedError {
        case feed = "This build has no valid HTTPS update feed."
        case key = "This build has no valid update-signing public key."
        var errorDescription: String? { rawValue }
    }
    init(info: [String: Any]) throws {
        guard let raw = info["SUFeedURL"] as? String,
              let parts = URLComponents(string: raw), parts.scheme == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, !parts.path.isEmpty,
              let feed = parts.url else { throw Invalid.feed }
        guard let key = info["SUPublicEDKey"] as? String,
              let data = Data(base64Encoded: key), data.count == 32,
              data.base64EncodedString() == key else { throw Invalid.key }
        self.feed = feed; publicKey = key
    }
}

@MainActor protocol AppUpdateEngine: AnyObject {
    var changed: (@MainActor () -> Void)? { get set }
    var canCheck: Bool { get }
    var automaticChecks: Bool { get set }
    func start() throws
    func check()
}

@MainActor final class SparkleUpdateEngine: AppUpdateEngine {
    private let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    private var observations: [NSKeyValueObservation] = []
    var changed: (@MainActor () -> Void)?
    var canCheck: Bool { controller.updater.canCheckForUpdates }
    var automaticChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    func start() throws {
        try controller.updater.start()
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.changed?() }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.changed?() }
            }
        ]
    }
    func check() { controller.checkForUpdates(nil) }
}

@MainActor final class AppUpdates: ObservableObject {
    static let shared = AppUpdates(configuration: {
        try AppUpdateConfiguration(info: Bundle.main.infoDictionary ?? [:])
    })
    @Published private(set) var started = false
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = false
    @Published private(set) var status = "Updates haven’t been initialized."
    private let configuration: @MainActor () throws -> AppUpdateConfiguration
    private let makeEngine: @MainActor () -> any AppUpdateEngine
    private var engine: (any AppUpdateEngine)?
    private var attempted = false
    init(configuration: @escaping @MainActor () throws -> AppUpdateConfiguration,
         makeEngine: @escaping @MainActor () -> any AppUpdateEngine = { SparkleUpdateEngine() }) {
        self.configuration = configuration; self.makeEngine = makeEngine
    }
    func start() {
        guard !attempted else { return }; attempted = true
        do {
            _ = try configuration()
            let engine = makeEngine()
            engine.changed = { [weak self] in self?.refresh() }
            try engine.start(); self.engine = engine; started = true; refresh()
            status = "Updates come from Textem’s signed release feed. Installation asks for your approval."
        } catch {
            status = "Updates are unavailable. " + error.localizedDescription
        }
    }
    private func refresh() {
        canCheck = started && (engine?.canCheck ?? false)
        automaticChecks = engine?.automaticChecks ?? false
    }
    func setAutomaticChecks(_ enabled: Bool) {
        guard started, let engine, engine.automaticChecks != enabled else { return }
        // Sparkle persists this preference. Never rewrite it during startup.
        engine.automaticChecks = enabled; refresh()
    }
    @discardableResult func check() -> Bool {
        guard started, let engine, engine.canCheck else { return false }
        engine.check(); refresh(); return true
    }
}
