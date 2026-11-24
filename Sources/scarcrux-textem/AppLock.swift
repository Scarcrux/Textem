import AppKit
import LocalAuthentication
import OSLog
import SwiftUI

@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()
    nonisolated private static let log = Logger(subsystem: "com.scarcrux.textem", category: "AppLock")
    private static let enabledKey = "requireAppUnlock"
    private static let focusKey = "lockOnFocusLoss"
    private static let awayKey = "lockWhenAway"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isLocked: Bool
    @Published private(set) var isAuthenticating = false
    @Published private(set) var authenticationFailed = false
    @Published var lockWhenAway: Bool {
        didSet {
            defaults.set(lockWhenAway, forKey: Self.awayKey)
            scheduleAwayLock()
        }
    }
    @Published var lockOnFocusLoss: Bool {
        didSet { defaults.set(lockOnFocusLoss, forKey: Self.focusKey) }
    }
    var onLockChanged: (() -> Void)?

    private let defaults: UserDefaults
    private let authenticate: @MainActor (LAContext, LAPolicy, String) async -> Bool
    private let awayDelay: Duration
    private var context: LAContext?
    private var awayTask: Task<Void, Never>?
    private var promptedDuringFocus = false
    private var isAway = false
    private var lastActivity = ContinuousClock.now

    init(defaults: UserDefaults = .standard, awayDelay: Duration = .seconds(300),
         authenticate: @escaping @MainActor (LAContext, LAPolicy, String) async -> Bool = { context, policy, reason in
             await withCheckedContinuation { continuation in
                 context.evaluatePolicy(policy, localizedReason: reason) { success, error in
                     if let code = (error as? LAError)?.code.rawValue {
                         AppLock.log.debug("Authentication policy \(policy.rawValue) returned \(code)")
                     }
                     continuation.resume(returning: success)
                 }
             }
         }) {
        self.defaults = defaults
        self.awayDelay = awayDelay
        self.authenticate = authenticate
        let enabled = defaults.bool(forKey: Self.enabledKey)
        isEnabled = enabled
        isLocked = enabled
        lockOnFocusLoss = defaults.bool(forKey: Self.focusKey)
        lockWhenAway = defaults.bool(forKey: Self.awayKey)
    }

    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled, !isLocked, !isAuthenticating else { return }
        let reason = enabled ? "Turn on the Textem app lock." : "Turn off the Textem app lock."
        guard await verify(reason) else { return }
        defaults.set(enabled, forKey: Self.enabledKey)
        isEnabled = enabled
        scheduleAwayLock()
    }

    var hasTouchID: Bool {
        let probe = LAContext()
        _ = probe.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return probe.biometryType == .touchID
    }

    @discardableResult
    func unlock(using policy: LAPolicy = .deviceOwnerAuthentication) async -> Bool {
        guard isLocked else { return true }
        promptedDuringFocus = true
        guard await verify("Unlock Textem to see your messages.", using: policy) else { return false }
        isLocked = false
        scheduleAwayLock()
        onLockChanged?()
        return true
    }

    func promptToUnlockOnFocus() async {
        guard isLocked, !isAway, !promptedDuringFocus else { return }
        await unlock()
    }

    func authorizeAction(asking requestUnlock: () async -> Bool) async -> Bool {
        if !isLocked { return true }
        guard await requestUnlock() else { return false }
        return !isLocked
    }

    func lock() {
        awayTask?.cancel()
        cancelAuthentication()
        authenticationFailed = false
        guard isEnabled, !isLocked else { return }
        isLocked = true
        onLockChanged?()
    }

    func cancelAuthentication() {
        context?.invalidate()
        context = nil
        isAuthenticating = false
    }

    func setAway(_ away: Bool) {
        guard away != isAway else { return }
        isAway = away
        // The system authentication dialog can temporarily take focus.
        if away && !isAuthenticating { promptedDuringFocus = false }
        if away && lockOnFocusLoss && isEnabled && !isLocked {
            lock()
        } else {
            scheduleAwayLock()
        }
    }

    func noteActivity() {
        if !isAway { lastActivity = .now }
    }

    private func scheduleAwayLock() {
        awayTask?.cancel()
        guard isEnabled, !isLocked, lockWhenAway else { return }
        lastActivity = .now
        awayTask = Task { [weak self, awayDelay] in
            var deadline = ContinuousClock.now.advanced(by: awayDelay)
            while !Task.isCancelled {
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                guard let self else { return }
                deadline = self.lastActivity.advanced(by: awayDelay)
                if deadline <= .now {
                    self.lock()
                    return
                }
            }
        }
    }

    private func verify(_ reason: String, using policy: LAPolicy = .deviceOwnerAuthentication) async -> Bool {
        guard context == nil else { return false }
        let attempt = LAContext()
        context = attempt
        isAuthenticating = true
        authenticationFailed = false
        if policy == .deviceOwnerAuthenticationWithBiometrics {
            // A separate system unlock button remains available for password entry.
            attempt.localizedFallbackTitle = ""
        }
        let success = await authenticate(attempt, policy, reason)
        // A lock event, window closure or newer attempt invalidates this result.
        guard context === attempt else { return false }
        context = nil
        isAuthenticating = false
        authenticationFailed = !success
        attempt.invalidate()
        return success
    }
}

struct AppLockView: View {
    @ObservedObject var lock: AppLock
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 28))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("Textem is locked").font(.title2.bold())
            Text(lock.authenticationFailed ? "Textem couldn’t unlock. Try again." : "Use Touch ID or your Mac password to see your messages.")
                .foregroundStyle(.secondary)
            HStack {
                if lock.hasTouchID {
                    Button("Use Touch ID") {
                        Task { await lock.unlock(using: .deviceOwnerAuthenticationWithBiometrics) }
                    }
                }
                Button(lock.isAuthenticating ? "Waiting for macOS…" : "Unlock") {
                    Task { await lock.unlock() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .disabled(lock.isAuthenticating)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
