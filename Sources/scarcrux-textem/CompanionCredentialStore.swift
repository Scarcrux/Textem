import Foundation
import Security

/// A private, device-local Keychain item. Empty data is a durable disconnect,
/// distinct from never configured; disconnect must not fall back to debugging.
struct CompanionCredentialStore: Sendable {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.textem.companion.connection",
         kSecAttrAccount as String: "paired-phone",
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false]
    }
    func load() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CompanionConnectionError.secureStorage }
        return data
    }
    func save(_ data: Data) throws {
        if !data.isEmpty { _ = try CompanionPairing.parse(data) }
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw CompanionConnectionError.secureStorage }
        var insert = query; insert.merge(values, uniquingKeysWith: { _, new in new })
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw CompanionConnectionError.secureStorage }
    }
}

struct CompanionJournalTransport: Sendable {
    var load: @Sendable () throws -> Data? = { try CompanionCredentialStore().load() }
    var network: @Sendable (CompanionPairing) async throws -> PhoneNotificationJournal = {
        try await CompanionHTTPSJournalClient().fetch(pairing: $0)
    }
    var developer: @Sendable (String) async throws -> PhoneNotificationJournal = {
        try await PhoneImageADBClient.shared.fetchNotificationJournal(endpoint: $0)
    }
    func fetch(developerEndpoint: String) async throws -> PhoneNotificationJournal {
        let saved = try load()
        let journal: PhoneNotificationJournal
        if let saved {
            guard !saved.isEmpty else { throw CompanionConnectionError.disconnected }
            journal = try await network(CompanionPairing.parse(saved))
        } else {
            // Preserve an existing developer setup until explicitly paired.
            journal = try await developer(developerEndpoint)
        }
        try Task.checkCancellation()
        guard try load() == saved else { throw CompanionConnectionError.disconnected }
        return journal
    }
}
