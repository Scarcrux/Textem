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
    // Display metadata is separate so older builds can still read history.json.
    // A name never establishes a source binding or grants navigation authority.
    private struct Name: Codable {
        let schema: Int
        let accountKey: String
        let conversationKey: String
        let displayName: String
    }
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
        try writePrivate(data, filename: "history.json", in: directory)
    }
    private static func writePrivate(_ data: Data, filename: String, in directory: URL) throws {
        try check(directory, create: true)
        let target = directory.appendingPathComponent(filename)
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
    static func cleanName(_ value: String) -> String? {
        let name = String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.utf8.count <= 1024 ? name : nil
    }
    private static func nameFile(_ record: Record, in directory: URL) throws -> URL {
        guard [record.accountKey, record.conversationKey].allSatisfy({ $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }) else { throw PhoneHistoryError.invalid }
        return directory.appendingPathComponent(record.conversationKey + ".name.json")
    }
    static func displayName(for record: Record, in directory: URL = directory) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        guard try exists(directory) else { return nil }; try check(directory)
        let file = try nameFile(record, in: directory)
        guard try exists(file) else { return nil }
        let data = try PhoneImageStore.readPrivate(file, maximum: 4096)
        let fields = try PhoneNotificationJSON.object(data, maximum: 4096)
        guard Set(fields.keys) == ["schema", "accountKey", "conversationKey", "displayName"],
              PhoneNotificationJSON.integer(fields["schema"]),
              let value = try? JSONDecoder().decode(Name.self, from: data), value.schema == 1,
              value.accountKey == record.accountKey, value.conversationKey == record.conversationKey,
              cleanName(value.displayName) == value.displayName else { throw PhoneHistoryError.invalid }
        return value.displayName
    }
    private static func removeName(_ record: Record, in directory: URL) throws {
        let file = try nameFile(record, in: directory)
        if try exists(file) {
            _ = try PhoneImageStore.readPrivate(file, maximum: 4096)
            try FileManager.default.removeItem(at: file)
        }
    }
    /// The returned flag concerns optional naming only. Message saving remains
    /// successful if a display name cannot be written; callers disclose that.
    @discardableResult static func link(_ snapshot: PhoneHistorySnapshot, to context: PhoneImageConversation, in directory: URL = directory) throws -> Bool {
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
        guard let name = cleanName(context.label) else { return false }
        do {
            let value = Name(schema: 1, accountKey: PhoneConversationStore.accountKey(context.accountID), conversationKey: key, displayName: name)
            try writePrivate(JSONEncoder().encode(value), filename: key + ".name.json", in: directory)
            return true
        } catch { return false }
    }
    static func unlink(_ context: PhoneImageConversation, in directory: URL = directory) throws {
        lock.lock(); defer { lock.unlock() }
        guard let key = context.key else { throw PhoneHistoryError.invalid }
        let records = try load(in: directory)
        for record in records where record.conversationKey == key && record.accountKey == PhoneConversationStore.accountKey(context.accountID) {
            try removeName(record, in: directory)
        }
        try write(records.filter { $0.conversationKey != key || $0.accountKey != PhoneConversationStore.accountKey(context.accountID) }, in: directory)
    }
    static func removeAccount(_ id: UUID, in directory: URL = directory) throws {
        lock.lock(); defer { lock.unlock() }
        guard try exists(directory) else { return }
        let records = try load(in: directory)
        for record in records where record.accountKey == PhoneConversationStore.accountKey(id) { try removeName(record, in: directory) }
        try write(records.filter { $0.accountKey != PhoneConversationStore.accountKey(id) }, in: directory)
    }
}
