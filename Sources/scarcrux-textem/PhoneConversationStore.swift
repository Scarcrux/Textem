import Darwin
import Foundation

enum PhoneConversationError: String, LocalizedError {
    case invalid = "The saved conversation previews were refused because their format or source is invalid."
    case alreadyLinked = "That phone source or conversation is already linked. Unlink it before assigning a different source."
    case full = "The conversation preview library is full. Unlink a conversation before adding another."
    var errorDescription: String? { rawValue }
}

/// A notification source is not a Google web route. Only explicit confirmation
/// creates this mapping. Hashes omit labels/raw routes; preview content is private.
enum PhoneConversationStore {
    struct Record: Codable, Equatable, Sendable {
        let accountKey: String
        let conversationKey: String
        let sourceKey: String
        var samples: [PhoneNotificationSnapshot]
    }
    private struct Library: Codable { let schema: Int; var records: [Record] }
    private static let lock = NSRecursiveLock()
    static let maximumBytes = 16 * 1024 * 1024
    static var directory: URL { PhoneNotificationStore.directory.deletingLastPathComponent().appendingPathComponent("ConversationPreviews") }
    static func accountKey(_ id: UUID) -> String { PhoneImageManifest.digest(Data(id.uuidString.utf8)) }
    static func sourceKey(_ sample: PhoneNotificationSnapshot) -> String {
        PhoneImageManifest.digest(Data((sample.installID + ":" + sample.sourceKey).utf8))
    }
    private static func check(_ directory: URL, create: Bool = false) throws {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT, create else { throw PhoneNotificationError.privateFile }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard lstat(directory.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == getuid(), info.st_mode & mode_t(0o077) == 0 else { throw PhoneNotificationError.privateFile }
    }
    private static func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        guard errno == ENOENT else { throw PhoneNotificationError.privateFile }; return false
    }
    static func load(in directory: URL = directory) throws -> [Record] {
        lock.lock(); defer { lock.unlock() }
        guard try exists(directory) else { return [] }; try check(directory)
        let file = directory.appendingPathComponent("previews.json")
        guard try exists(file) else { return [] }
        let data = try PhoneImageStore.readPrivate(file, maximum: maximumBytes)
        let object = try PhoneNotificationJSON.object(data, maximum: maximumBytes)
        guard Set(object.keys) == ["schema", "records"], PhoneNotificationJSON.integer(object["schema"]),
              let rows = object["records"] as? [[String: Any]],
              rows.allSatisfy({ Set($0.keys) == ["accountKey", "conversationKey", "sourceKey", "samples"] }),
              let library = try? JSONDecoder().decode(Library.self, from: data), library.schema == 1,
              library.records.count <= 20, Set(library.records.map(\.conversationKey)).count == library.records.count,
              Set(library.records.map(\.sourceKey)).count == library.records.count else { throw PhoneConversationError.invalid }
        for record in library.records {
            guard [record.accountKey, record.conversationKey, record.sourceKey].allSatisfy({ $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }),
                  (1...4).contains(record.samples.count) else { throw PhoneConversationError.invalid }
            for sample in record.samples {
                _ = try PhoneNotificationSnapshot.parse(JSONEncoder().encode(sample), requireFresh: false)
                guard sourceKey(sample) == record.sourceKey else { throw PhoneConversationError.invalid }
            }
        }
        return library.records
    }
    static func record(for context: PhoneImageConversation, in directory: URL = directory) throws -> Record? {
        guard let key = context.key else { throw PhoneConversationError.invalid }
        return try load(in: directory).first { $0.conversationKey == key && $0.accountKey == accountKey(context.accountID) }
    }
    private static func write(_ records: [Record], in directory: URL) throws {
        let data = try JSONEncoder().encode(Library(schema: 1, records: records))
        guard data.count <= maximumBytes else { throw PhoneConversationError.full }
        try check(directory, create: true)
        let url = directory.appendingPathComponent("previews.json")
        if try exists(url) { _ = try PhoneImageStore.readPrivate(url, maximum: maximumBytes) }
        try data.write(to: url, options: .atomic)
        guard chmod(url.path, 0o600) == 0 else { throw PhoneNotificationError.privateFile }
    }
    static func link(_ sample: PhoneNotificationSnapshot, to context: PhoneImageConversation, in directory: URL = directory) throws {
        lock.lock(); defer { lock.unlock() }
        _ = try PhoneNotificationSnapshot.parse(JSONEncoder().encode(sample), requireFresh: false)
        guard let key = context.key else { throw PhoneConversationError.invalid }
        var records = try load(in: directory)
        if let old = records.first(where: { $0.sourceKey == sourceKey(sample) || $0.conversationKey == key }) {
            guard old.sourceKey == sourceKey(sample), old.conversationKey == key,
                  old.accountKey == accountKey(context.accountID) else { throw PhoneConversationError.alreadyLinked }
            try ingest(sample, for: context, in: directory); return
        }
        guard records.count < 20 else { throw PhoneConversationError.full }
        records.append(Record(accountKey: accountKey(context.accountID), conversationKey: key, sourceKey: sourceKey(sample), samples: [sample]))
        try write(records, in: directory)
    }
    private static func fingerprint(_ sample: PhoneNotificationSnapshot) throws -> String {
        // Polling/active scans must not create a fresh copy of unchanged content.
        var object = try PhoneNotificationJSON.object(JSONEncoder().encode(sample), maximum: PhoneNotificationSnapshot.maximumBytes)
        object.removeValue(forKey: "captured_at_ms"); object.removeValue(forKey: "origin")
        return PhoneImageManifest.digest(try JSONSerialization.data(withJSONObject: object, options: .sortedKeys))
    }
    static func ingest(_ sample: PhoneNotificationSnapshot, for context: PhoneImageConversation, in directory: URL = directory) throws {
        lock.lock(); defer { lock.unlock() }
        _ = try PhoneNotificationSnapshot.parse(JSONEncoder().encode(sample), requireFresh: false)
        guard let key = context.key else { throw PhoneConversationError.invalid }
        var records = try load(in: directory)
        guard let index = records.firstIndex(where: { $0.conversationKey == key && $0.accountKey == accountKey(context.accountID) }),
              records[index].sourceKey == sourceKey(sample) else { throw PhoneConversationError.invalid }
        let signature = try fingerprint(sample)
        if try records[index].samples.contains(where: { try fingerprint($0) == signature }) { return }
        records[index].samples.append(sample)
        records[index].samples.sort { $0.capturedAtMS < $1.capturedAtMS }
        records[index].samples = Array(records[index].samples.suffix(4))
        try write(records, in: directory)
    }
    static func unlink(_ context: PhoneImageConversation, in directory: URL = directory) throws {
        lock.lock(); defer { lock.unlock() }
        guard let key = context.key else { throw PhoneConversationError.invalid }
        let records = try load(in: directory).filter { $0.conversationKey != key || $0.accountKey != accountKey(context.accountID) }
        try write(records, in: directory)
    }
    static func removeAccount(_ id: UUID, in directory: URL = directory) throws {
        lock.lock(); defer { lock.unlock() }
        guard try exists(directory) else { return }
        try write(load(in: directory).filter { $0.accountKey != accountKey(id) }, in: directory)
    }
}
