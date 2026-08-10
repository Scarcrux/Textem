import Foundation

// A signed-in Google Messages account. Each account maps to an isolated
// website data store so sessions don't collide. The first/original account
// carries `storeIdentifier == nil`, meaning it uses WKWebsiteDataStore.default()
// — that preserves the session that was paired before multi-account existed.
struct Account: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var storeIdentifier: UUID?

    init(id: UUID = UUID(), name: String, storeIdentifier: UUID?) {
        self.id = id
        self.name = name
        self.storeIdentifier = storeIdentifier
    }
}
