import AppKit
import AuthenticationServices
import NativeAutoFillCore
import Security

@MainActor protocol CodeIndexPublishing {
    func replace(_ entries: [CodeIndexEntry]) async throws
}

enum NativeCodeSetupError: Error { case notEnabled, unsupported }

@MainActor private struct SystemCodeIndex: CodeIndexPublishing {
    func replace(_ entries: [CodeIndexEntry]) async throws {
        guard #available(macOS 15, *) else { throw NativeCodeSetupError.unsupported }
        let store = ASCredentialIdentityStore.shared
        let isEnabled = await withCheckedContinuation { continuation in
            store.getState { continuation.resume(returning: $0.isEnabled) }
        }
        guard isEnabled else {
            throw NativeCodeSetupError.notEnabled
        }
        let identities = entries.map {
            ASOneTimeCodeCredentialIdentity(serviceIdentifier: ASCredentialServiceIdentifier(identifier: $0.domain, type: .domain),
                                           label: $0.label, recordIdentifier: $0.recordID)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.replaceCredentialIdentities(identities) { success, error in
                if success { continuation.resume() }
                else { continuation.resume(throwing: error ?? NativeCodeSetupError.unsupported) }
            }
        }
    }
}

@MainActor enum NativeCodeRuntime {
    static var available: Bool {
        guard #available(macOS 15, *), let plugins = Bundle.main.builtInPlugInsURL,
              Bundle(url: plugins.appendingPathComponent("TextemCodeProvider.appex"))?.bundleIdentifier == "com.scarcrux.textem.codeprovider" else { return false }
        var code: SecCode?; var staticCode: SecStaticCode?; var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              info[kSecCodeInfoTeamIdentifier as String] as? String == "K466Z7J2AS",
              let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              entitlements["com.apple.developer.authentication-services.autofill-credential-provider"] as? Bool == true,
              let groups = entitlements["keychain-access-groups"] as? [String],
              groups.contains(KeychainCodeStorage.accessGroup) else { return false }
        return true
    }
}

@MainActor final class NativeAutoFillCoordinator: ObservableObject {
    static let shared = NativeAutoFillCoordinator()
    @Published private(set) var enabled = false
    @Published private(set) var status: String
    let available: Bool
    private let vault: CodeVault
    private let publisher: any CodeIndexPublishing
    private let clock: () -> Date
    private let accountExists: (UUID) -> Bool
    private var publication: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var revision = UUID()

    init(vault: CodeVault? = nil, publisher: (any CodeIndexPublishing)? = nil,
         available: Bool? = nil, clock: @escaping () -> Date = Date.init,
         accountExists: @escaping (UUID) -> Bool = { id in AccountStore.shared.accounts.contains { $0.id == id } }) {
        self.vault = vault ?? CodeVault(storage: KeychainCodeStorage())
        self.publisher = publisher ?? SystemCodeIndex()
        self.available = available ?? NativeCodeRuntime.available
        self.clock = clock; self.accountExists = accountExists
        status = "Requires an AutoFill-provisioned build with the signed Textem Codes extension and shared Keychain access. No codes are being collected."
        if self.available {
            do { enabled = try self.vault.isEnabled(); status = enabled ? "Ready to import fresh codes from explicitly linked phone notification sources." : "Native code AutoFill is off." }
            catch { status = "Protected code storage is locked, unavailable or invalid. No code was read." }
        }
    }

    func start() { guard available else { return }; Task { await synchronize() } }
    func setEnabled(_ value: Bool) async {
        guard available else { return }
        revision = UUID(); expiry?.cancel()
        do {
            if value { try vault.enable() } else { try vault.disableAndClear() }
            enabled = value
            await synchronize()
        } catch { status = "Could not change protected code storage. No fallback storage was used." }
    }

    func bind(_ snapshot: PhoneNotificationSnapshot, accountID: UUID) async {
        guard available, enabled, accountExists(accountID),
              let source = NotificationCodeSource(installationID: snapshot.installID, shortcutKey: snapshot.sourceKey),
              snapshot.kind == "NOTIFICATION_CONTENT" else { return }
        do {
            try vault.bind(source, to: accountID)
            await ingest(snapshot)
            // Rebinding revokes old records even if this snapshot is truncated
            // or otherwise ineligible to contribute a replacement code.
            await synchronize()
        } catch { status = "Source linking failed in protected storage; no account or business name was guessed." }
    }

    func ingest(_ snapshot: PhoneNotificationSnapshot) async {
        guard available, enabled, snapshot.kind == "NOTIFICATION_CONTENT", !snapshot.truncated,
              let source = NotificationCodeSource(installationID: snapshot.installID, shortcutKey: snapshot.sourceKey) else { return }
        do {
            for message in snapshot.messages where !message.truncated {
                _ = try vault.ingest(source: source, origin: snapshot.origin, message: message.text,
                                     timestamp: Date(timeIntervalSince1970: Double(message.timestampMS) / 1000), now: clock())
            }
            await synchronize()
        } catch CodeVaultError.unboundSource {
            status = "Notification source is unlinked. Explicitly choose its Textem account before offering codes."
        } catch { status = "Notification code import was refused by protected storage. No fallback or clipboard write occurred." }
    }

    func removeAccount(_ id: UUID) throws {
        guard available else { return }
        try vault.removeAccount(id)
        revision = UUID()
        Task { await synchronize() }
    }
    func clearSource(_ snapshot: PhoneNotificationSnapshot) throws {
        guard available, let source = NotificationCodeSource(installationID: snapshot.installID, shortcutKey: snapshot.sourceKey) else { return }
        try vault.unbind(source)
        revision = UUID()
        Task { await synchronize() }
    }

    // Serialize publication: an in-flight old update cannot finish after a newer
    // clear and leave stale metadata behind. Each queued job rereads the vault.
    func synchronize() async {
        guard available else { return }
        let previous = publication
        let id = revision
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                try vault.prune(now: clock())
                let samples = try vault.eligible(now: clock())
                scheduleExpiry(samples)
                try await publisher.replace(CodeIndexEntry.project(samples, now: clock()))
                guard revision == id else { return }
                status = enabled ? "Native provider updated: \(CodeIndexEntry.project(samples, now: clock()).count) fresh domain-matched code(s). Phone imports are manual; continuous sync is not enabled." : "Native code AutoFill is off. Protected samples and source bindings were deleted."
            } catch NativeCodeSetupError.notEnabled {
                if revision == id {
                    status = enabled ? "Enable Textem Codes in System Settings → General → AutoFill & Passwords. Codes stay protected; native suggestions are not active." : "Native code AutoFill is off. Protected samples and source bindings were deleted; the OS has disabled its suggestion index."
                }
            } catch {
                if revision == id { status = "Native AutoFill update failed or protected storage is locked. No native suggestion success is claimed." }
            }
        }
        publication = task
        await task.value
    }

    private func scheduleExpiry(_ samples: [CodeSample]) {
        expiry?.cancel()
        guard let date = samples.map({ $0.receivedAt.addingTimeInterval(180) }).min() else { return }
        let delay = max(0.01, date.timeIntervalSince(clock()))
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.synchronize()
        }
    }
}
