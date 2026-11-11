import Foundation
import CryptoKit
import Security
import LocalAuthentication

@MainActor public protocol CodeStorage {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func delete() throws
}

public enum CodeVaultError: LocalizedError, Equatable {
    case unavailable(Int32), malformed, disabled, unboundSource, capacity
    public var errorDescription: String? {
        switch self {
        case .unavailable(let status): "Protected code storage is unavailable (Keychain status \(status)). Check Mac unlock state and signed shared-Keychain capabilities; no fallback storage was used."
        case .malformed: "The protected code vault is invalid. Use Delete native codes and source links to clear it safely."
        case .disabled: "Native code AutoFill is off. No code was stored."
        case .unboundSource: "This exact phone installation and notification source has no explicit account link."
        case .capacity: "The protected code vault reached its bound. Clear saved codes or let current codes expire."
        }
    }
}

/// No login-Keychain/file fallback. The OS enforces membership in this explicit
/// group; an unprovisioned process must fail rather than weakening protection.
@MainActor public final class KeychainCodeStorage: CodeStorage {
    public static let accessGroup = "K466Z7J2AS.com.scarcrux.textem.codes"
    public init() {}
    private var query: [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.scarcrux.textem.autofill",
         kSecAttrAccount as String: "vault.v1",
         kSecAttrAccessGroup as String: Self.accessGroup,
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false,
         kSecUseAuthenticationContext as String: context]
    }
    public func read() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CodeVaultError.unavailable(status) }
        guard let data = value as? Data, data.count <= CodeVault.maximumBytes else { throw CodeVaultError.malformed }
        return data
    }
    public func write(_ data: Data) throws {
        guard data.count <= CodeVault.maximumBytes else { throw CodeVaultError.capacity }
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            attributes.forEach { insert[$0.key] = $0.value }
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw CodeVaultError.unavailable(added) }
        } else if status != errSecSuccess { throw CodeVaultError.unavailable(status) }
    }
    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CodeVaultError.unavailable(status) }
    }
}

public struct NotificationCodeSource: Codable, Equatable, Sendable {
    public let installationID: UUID
    public let shortcutKey: String
    public init?(installationID: String, shortcutKey: String) {
        guard let id = UUID(uuidString: installationID),
              shortcutKey.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }
        self.installationID = id; self.shortcutKey = shortcutKey
    }
}

/// One host process writes; extensions read only. All local calls are serialized
/// on the main actor. No real message or title is persisted in this vault.
@MainActor public final class CodeVault {
    public static let maximumBytes = 32_768
    private struct Binding: Codable { let source: NotificationCodeSource; let accountID: UUID }
    private struct Record: Codable { let receipt: String; let sample: CodeSample }
    private struct State: Codable {
        var schema = 1; var enabled = false
        var bindings: [Binding] = []; var records: [Record] = []
    }
    private let storage: any CodeStorage
    public init(storage: any CodeStorage) { self.storage = storage }

    private func load() throws -> State {
        guard let data = try storage.read() else { return State() }
        guard data.count <= Self.maximumBytes,
              let state = try? JSONDecoder().decode(State.self, from: data), state.schema == 1,
              state.bindings.count <= 16, state.records.count <= 16,
              state.enabled || (state.bindings.isEmpty && state.records.isEmpty),
              Set(state.bindings.map { $0.source.installationID.uuidString + $0.source.shortcutKey }).count == state.bindings.count,
              Set(state.records.map(\.receipt)).count == state.records.count,
              Set(state.records.map { $0.sample.id }).count == state.records.count,
              state.bindings.allSatisfy({ NotificationCodeSource(installationID: $0.source.installationID.uuidString, shortcutKey: $0.source.shortcutKey) != nil }),
              state.records.allSatisfy({ record in
                  record.receipt.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil &&
                  state.bindings.contains(where: { $0.accountID == record.sample.accountID }) &&
                  record.sample.consent && CodeSample.validDomain(record.sample.domain) &&
                  record.sample.code.range(of: "^[0-9]{4,8}$", options: .regularExpression) != nil
              }) else { throw CodeVaultError.malformed }
        return state
    }
    private func save(_ state: State) throws {
        let data = try JSONEncoder().encode(state)
        guard data.count <= Self.maximumBytes else { throw CodeVaultError.capacity }
        try storage.write(data)
    }
    public func isEnabled() throws -> Bool { try load().enabled }
    public func enable() throws { var state = try load(); state.enabled = true; try save(state) }
    public func disableAndClear() throws { try storage.delete() }
    public func bind(_ source: NotificationCodeSource, to accountID: UUID) throws {
        var state = try load()
        guard state.enabled else { throw CodeVaultError.disabled }
        // Rebinding invalidates prior code records rather than carrying them to a new account.
        if let previous = state.bindings.first(where: { $0.source == source }) {
            state.records.removeAll { $0.sample.accountID == previous.accountID }
        }
        state.bindings.removeAll { $0.source == source }
        guard state.bindings.count < 16 else { throw CodeVaultError.capacity }
        state.bindings.append(Binding(source: source, accountID: accountID)); try save(state)
    }
    public func removeAccount(_ accountID: UUID) throws {
        var state = try load()
        guard state.bindings.contains(where: { $0.accountID == accountID }) || state.records.contains(where: { $0.sample.accountID == accountID }) else { return }
        state.bindings.removeAll { $0.accountID == accountID }
        state.records.removeAll { $0.sample.accountID == accountID }; try save(state)
    }
    public func unbind(_ source: NotificationCodeSource) throws {
        var state = try load()
        guard let binding = state.bindings.first(where: { $0.source == source }) else { return }
        state.bindings.removeAll { $0.source == source }
        // Conservative revocation: discard all codes in this local account.
        state.records.removeAll { $0.sample.accountID == binding.accountID }
        try save(state)
    }
    public func eligible(now: Date) throws -> [CodeSample] {
        let state = try load()
        return state.enabled ? state.records.map(\.sample).filter { $0.eligible(domain: $0.domain, now: now) } : []
    }
    public func prune(now: Date) throws {
        var state = try load()
        let count = state.records.count
        state.records.removeAll { !$0.sample.eligible(domain: $0.sample.domain, now: now) }
        if state.records.count != count { try save(state) }
    }

    @discardableResult public func ingest(source: NotificationCodeSource, origin: String, message: String,
                                          timestamp: Date, now: Date) throws -> Bool {
        var state = try load()
        guard state.enabled else { throw CodeVaultError.disabled }
        guard let binding = state.bindings.first(where: { $0.source == source }) else { throw CodeVaultError.unboundSource }
        guard origin == "POSTED", timestamp.timeIntervalSince1970 > 0,
              let sample = CodeSample(message: message, accountID: binding.accountID, receivedAt: timestamp, consent: true),
              sample.eligible(domain: sample.domain, now: now) else { return false }
        // Hash only opaque scope + original timestamp + domain + code. A fresh
        // capture time cannot turn a repeated notification into a fresh message.
        let fields = [source.installationID.uuidString, source.shortcutKey,
                      String(timestamp.timeIntervalSince1970), sample.domain, sample.code]
        let receipt = SHA256.hash(data: Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8)).map { String(format: "%02x", $0) }.joined()
        if state.records.contains(where: { $0.receipt == receipt }) { return false }
        state.records.removeAll { !$0.sample.eligible(domain: $0.sample.domain, now: now) }
        guard state.records.count < 16 else { throw CodeVaultError.capacity }
        state.records.append(Record(receipt: receipt, sample: sample)); try save(state)
        return true
    }
}
