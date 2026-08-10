import Foundation
import WebKit

// Persists the account list + which one is active, and resolves each account
// to a WKWebsiteDataStore. Named persistent stores need macOS 14; on 13 every
// account falls back to .default() (so adding accounts is disabled there).
@MainActor
final class AccountStore {
    static let shared = AccountStore()

    private let defaults = UserDefaults.standard
    private let accountsKey = "accounts.v1"
    private let activeKey = "activeAccountID"

    private(set) var accounts: [Account]
    private(set) var activeID: UUID

    private init() {
        if let data = defaults.data(forKey: accountsKey),
           let list = try? JSONDecoder().decode([Account].self, from: data),
           !list.isEmpty {
            accounts = list
        } else {
            // Seed with the original session (nil identifier => .default()).
            accounts = [Account(name: "Account 1", storeIdentifier: nil)]
        }

        if let raw = defaults.string(forKey: activeKey),
           let id = UUID(uuidString: raw),
           accounts.contains(where: { $0.id == id }) {
            activeID = id
        } else {
            activeID = accounts[0].id
        }
        persist()
    }

    var active: Account {
        accounts.first { $0.id == activeID } ?? accounts[0]
    }

    // macOS 14 is required for multiple named persistent stores.
    var canAddAccounts: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    func setActive(_ id: UUID) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        activeID = id
        persist()
    }

    @discardableResult
    func addAccount(name: String) -> Account {
        let account = Account(name: name, storeIdentifier: UUID())
        accounts.append(account)
        persist()
        return account
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].name = name
        persist()
    }

    func remove(_ id: UUID) {
        guard accounts.count > 1,
              let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        let removed = accounts.remove(at: index)
        if let sid = removed.storeIdentifier, #available(macOS 14.0, *) {
            WKWebsiteDataStore.remove(forIdentifier: sid) { _ in }
        }
        if activeID == id { activeID = accounts[0].id }
        persist()
    }

    func dataStore(for account: Account) -> WKWebsiteDataStore {
        if let sid = account.storeIdentifier, #available(macOS 14.0, *) {
            return WKWebsiteDataStore(forIdentifier: sid)
        }
        return .default()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: accountsKey)
        }
        defaults.set(activeID.uuidString, forKey: activeKey)
    }
}
