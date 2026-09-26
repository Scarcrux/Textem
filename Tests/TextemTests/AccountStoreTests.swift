import XCTest
@testable import scarcrux_textem

@MainActor
final class AccountStoreTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-\(UUID().uuidString)")!
    }

    func testSeedsSingleDefaultAccount() {
        let store = AccountStore(defaults: freshDefaults())
        XCTAssertEqual(store.accounts.count, 1)
        // The original account must keep the .default() store (nil identifier)
        // so the pre-existing pairing survives the multi-account migration.
        XCTAssertNil(store.accounts[0].storeIdentifier)
        XCTAssertEqual(store.activeID, store.accounts[0].id)
    }

    func testAddAccountGetsIsolatedStore() {
        let store = AccountStore(defaults: freshDefaults())
        let account = store.addAccount(name: "Work")
        XCTAssertEqual(store.accounts.count, 2)
        XCTAssertNotNil(account.storeIdentifier)
        XCTAssertEqual(store.accounts.last?.name, "Work")
    }

    func testRenameAndSetActive() {
        let store = AccountStore(defaults: freshDefaults())
        let account = store.addAccount(name: "Work")
        store.rename(account.id, to: "Personal")
        XCTAssertEqual(store.accounts.last?.name, "Personal")
        store.setActive(account.id)
        XCTAssertEqual(store.active.id, account.id)
    }

    func testRemoveKeepsAtLeastOneAndReassignsActive() {
        let store = AccountStore(defaults: freshDefaults())
        let account = store.addAccount(name: "Work")
        store.setActive(account.id)
        var completionCalled = false
        store.remove(account.id) { error in
            XCTAssertNil(error)
            completionCalled = true
        }
        XCTAssertTrue(completionCalled)
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.activeID, store.accounts[0].id)

        // The final account cannot be removed.
        store.remove(store.accounts[0].id)
        XCTAssertEqual(store.accounts.count, 1)
    }

    func testPersistenceRoundTrip() {
        let defaults = freshDefaults()
        let first = AccountStore(defaults: defaults)
        let account = first.addAccount(name: "Work")
        first.setActive(account.id)

        let reloaded = AccountStore(defaults: defaults)
        XCTAssertEqual(reloaded.accounts.count, 2)
        XCTAssertEqual(reloaded.activeID, account.id)
        XCTAssertTrue(reloaded.accounts.contains { $0.name == "Work" })
    }

    func testAccountCodableRoundTrip() throws {
        let account = Account(name: "Example", storeIdentifier: UUID())
        let data = try JSONEncoder().encode(account)
        let decoded = try JSONDecoder().decode(Account.self, from: data)
        XCTAssertEqual(account, decoded)
    }
}
