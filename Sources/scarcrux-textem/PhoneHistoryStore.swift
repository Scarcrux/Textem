import Darwin
import Foundation

enum PhoneHistoryStore {
    struct Record: Codable, Equatable, Sendable {
        let accountKey: String
        let conversationKey: String
        let sourceKey: String
        let snapshot: PhoneHistorySnapshot
    }
    private struct Library: Codable { let schema: Int; let records: [Record] }
    private static let lock = NSRecursiveLock()
    static var directory: URL { PhoneConversationStore.directory.deletingLastPathComponent().appendingPathComponent("SelectedHistory") }
    static let maximumBytes = 16 * 1024 * 1024
    private static func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        guard errno == ENOENT else { throw PhoneNotificationError.privateFile }; return false
    }
    private static func check(_ directory: URL, create: Bool = false) throws {
        if try !exists(directory), create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_mode & 0o077 == 0 else { throw PhoneNotificationError.privateFile }
    }
    static func load(in directory: URL = directory) throws -> [Record] {
        lock.lock(); defer { lock.unlock() }
        guard try exists(directory) else { return [] }; try check(directory)
        let file = directory.appendingPathComponent("history.json")
        guard try exists(file) else { return [] }
        let data = try PhoneImageStore.readPrivate(file, maximum: maximumBytes)
        let object = try PhoneNotificationJSON.object(data, maximum: maximumBytes)
        guard Set(object.keys) == ["schema", "records"], PhoneNotificationJSON.integer(object["schema"]),
              let rows = object["records"] as? [[String: Any]], rows.allSatisfy({ Set($0.keys) == ["accountKey", "conversationKey", "sourceKey", "snapshot"] }),
              let library = try? JSONDecoder().decode(Library.self, from: data), library.schema == 1,
              library.records.count <= 20, Set(library.records.map(\.conversationKey)).count == library.records.count,
              Set(library.records.map(\.sourceKey)).count == library.records.count else { throw PhoneHistoryError.invalid }
        for record in library.records {
            guard [record.accountKey, record.conversationKey, record.sourceKey].allSatisfy({ $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }),
                  record.sourceKey == record.snapshot.bindingKey else { throw PhoneHistoryError.invalid }
            _ = try PhoneHistorySnapshot.parse(JSONEncoder().encode(record.snapshot), requireFresh: false)
        }
        return library.records
    }
    static func record(for context: PhoneImageConversation, in directory: URL = directory) throws -> Record? {
        guard let key = context.key else { throw PhoneHistoryError.invalid }
        return try load(in: directory).first { $0.conversationKey == key && $0.accountKey == PhoneConversationStore.accountKey(context.accountID) }
    }
    private static func write(_ records: [Record], in directory: URL) throws {
        let data = try JSONEncoder().encode(Library(schema: 1, records: records))
        guard data.count <= maximumBytes else { throw PhoneConversationError.full }
        try check(directory, create: true)
        let target = directory.appendingPathComponent("history.json")
        if try exists(target) { _ = try PhoneImageStore.readPrivate(target, maximum: maximumBytes) }
        // Establish owner-only permissions before the first byte is written.
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw PhoneNotificationError.privateFile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data); try handle.synchronize()
        guard rename(temporary.path, target.path) == 0 else { throw PhoneNotificationError.privateFile }
    }
    static func link(_ snapshot: PhoneHistorySnapshot, to context: PhoneImageConversation, in directory: URL = directory) throws {
        lock.lock(); defer { lock.unlock() }
        _ = try PhoneHistorySnapshot.parse(JSONEncoder().encode(snapshot))
        guard let key = context.key else { throw PhoneHistoryError.invalid }
        var records = try load(in: directory)
        if let index = records.firstIndex(where: { $0.conversationKey == key || $0.sourceKey == snapshot.bindingKey }) {
            let old = records[index]
            guard old.conversationKey == key, old.accountKey == PhoneConversationStore.accountKey(context.accountID),
                  old.sourceKey == snapshot.bindingKey else { throw PhoneConversationError.alreadyLinked }
            guard snapshot.capturedAtMS >= old.snapshot.capturedAtMS else { throw PhoneHistoryError.invalid }
            records.remove(at: index)
        }
        guard records.count < 20 else { throw PhoneConversationError.full }
        records.append(Record(accountKey: PhoneConversationStore.accountKey(context.accountID), conversationKey: key,
            sourceKey: snapshot.bindingKey, snapshot: snapshot))
        try write(records, in: directory)
    }
    static func unlink(_ context: PhoneImageConversation, in directory: URL = directory) throws {
        lock.lock(); defer { lock.unlock() }
        guard let key = context.key else { throw PhoneHistoryError.invalid }
        try write(load(in: directory).filter { $0.conversationKey != key || $0.accountKey != PhoneConversationStore.accountKey(context.accountID) }, in: directory)
    }
    static func removeAccount(_ id: UUID, in directory: URL = directory) throws {
        lock.lock(); defer { lock.unlock() }
        guard try exists(directory) else { return }
        try write(load(in: directory).filter { $0.accountKey != PhoneConversationStore.accountKey(id) }, in: directory)
    }
}
