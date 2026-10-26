import AppKit
import Darwin
import Foundation
import CoreFoundation

enum PhoneNotificationError: String, LocalizedError {
    case invalid = "The notification preview was refused: invalid, stale, synthetic or unsafe data."
    case unavailable = "No current content sample is available. Enable local content samples in the phone companion, then Refresh while a Google Messages notification exists."
    case changed = "The phone sample changed during transfer. Refresh to try again. Nothing was imported."
    case privateFile = "The local notification preview was refused because its storage is not private."
    case contentOff = "Local content samples are disabled on the phone. Enable that separate opt-in in the companion; notification access alone is not enough."
    case accessRequired = "Android notification access is missing or revoked. Approve the companion in Android settings; no messages were imported."
    case sourceRequired = "Google did not expose a usable conversation shortcut. Textem refused to guess a source from its title. The shared-image path remains available."
    case unsupported = "The latest notification exposes only an unsupported attachment or picture type. This is not a permission failure. Use Share → Save image for Mac for a graphic."
    case noContent = "The latest capture attempt exposed no usable individual Google notification preview. The previous Mac copy is unchanged; this does not prove message history is absent."
    case malformed = "The notification payload could not be decoded safely. No new preview was imported; this is not a request for more permissions."
    var errorDescription: String? { rawValue }
    static func forState(_ value: String) -> Self {
        switch value {
        case "OFF": .contentOff
        case "ACCESS_REQUIRED": .accessRequired
        case "SOURCE_REQUIRED": .sourceRequired
        case "URI_ONLY_UNSUPPORTED", "IMAGE_UNSUPPORTED": .unsupported
        case "NO_CONTENT", "SUMMARY_SKIPPED", "CLEARED": .noContent
        case "MALFORMED": .malformed
        default: .unavailable
        }
    }
}

/// Reject duplicate object keys before decoding; no parser gets to choose a different value.
enum PhoneNotificationJSON {
    private struct Frame { var object: Bool; var expectingKey = true; var keys = Set<String>() }
    static func integer(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return !["f", "d"].contains(String(cString: number.objCType))
    }
    static func object(_ data: Data, maximum: Int) throws -> [String: Any] {
        guard data.count <= maximum, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PhoneNotificationError.invalid
        }
        let bytes = Array(data); var index = 0; var frames: [Frame] = []
        while index < bytes.count {
            switch bytes[index] {
            case 123: frames.append(Frame(object: true))
            case 91: frames.append(Frame(object: false))
            case 125, 93: guard !frames.isEmpty else { throw PhoneNotificationError.invalid }; frames.removeLast()
            case 44: if !frames.isEmpty && frames[frames.count - 1].object { frames[frames.count - 1].expectingKey = true }
            case 58: if !frames.isEmpty { frames[frames.count - 1].expectingKey = false }
            case 34:
                let start = index; index += 1
                while index < bytes.count {
                    if bytes[index] == 92 { index += 2; continue }
                    if bytes[index] == 34 { break }; index += 1
                }
                guard index < bytes.count else { throw PhoneNotificationError.invalid }
                if !frames.isEmpty && frames[frames.count - 1].object && frames[frames.count - 1].expectingKey {
                    guard let key = try? JSONSerialization.jsonObject(with: Data(bytes[start...index]), options: .fragmentsAllowed) as? String,
                          frames[frames.count - 1].keys.insert(key).inserted else { throw PhoneNotificationError.invalid }
                }
            default: break
            }
            index += 1
        }
        guard frames.isEmpty else { throw PhoneNotificationError.invalid }; return object
    }
}

struct PhoneNotificationSnapshot: Codable, Equatable, Sendable {
    struct Message: Codable, Equatable, Sendable {
        let timestampMS: Int64; let text: String; let truncated: Bool
        enum CodingKeys: String, CodingKey { case timestampMS = "timestamp_ms", text, truncated }
    }
    struct Picture: Codable, Equatable, Sendable {
        let mime: String; let width: Int; let height: Int; let bytes: Int; let sha256: String; let dataBase64: String
        enum CodingKeys: String, CodingKey { case mime, width, height, bytes, sha256; case dataBase64 = "data_base64" }
        var data: Data? { Data(base64Encoded: dataBase64) }
    }
    let schema: Int; let kind: String; let capturedAtMS: Int64; let origin: String
    let installID: String; let sourceKey: String; let title: String; let messages: [Message]
    let truncated: Bool; let image: Picture?; let imageState: String; let uriAttachments: Int; let complete: Bool
    enum CodingKeys: String, CodingKey {
        case schema, kind, origin, title, messages, truncated, image, complete
        case capturedAtMS = "captured_at_ms", installID = "install_id", sourceKey = "source_key"
        case imageState = "image_state", uriAttachments = "uri_attachments"
    }
    static let maximumBytes = 2 * 1024 * 1024
    static func parse(_ data: Data, now: Date = Date(), requireFresh: Bool = true) throws -> Self {
        let keys: Set<String> = ["schema", "kind", "captured_at_ms", "origin", "install_id", "source_key", "title", "messages", "truncated", "image", "image_state", "uri_attachments", "complete"]
        let object = try PhoneNotificationJSON.object(data, maximum: maximumBytes)
        guard Set(object.keys) == keys, let value = try? JSONDecoder().decode(Self.self, from: data),
              PhoneNotificationJSON.integer(object["schema"]), PhoneNotificationJSON.integer(object["captured_at_ms"]),
              PhoneNotificationJSON.integer(object["uri_attachments"]),
              value.schema == 1, value.kind == "NOTIFICATION_CONTENT", !value.complete,
              ["POSTED", "ACTIVE_SCAN"].contains(value.origin),
              UUID(uuidString: value.installID)?.uuidString.lowercased() == value.installID,
              value.sourceKey.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              value.title.utf16.count <= 256, value.messages.count <= 10, (0...11).contains(value.uriAttachments),
              value.capturedAtMS >= 0, Double(value.capturedAtMS) <= now.timeIntervalSince1970 * 1000 + 300_000,
              !requireFresh || Double(value.capturedAtMS) >= now.timeIntervalSince1970 * 1000 - 1_800_000,
              let rows = object["messages"] as? [[String: Any]], rows.count == value.messages.count,
              rows.allSatisfy({ Set($0.keys) == ["timestamp_ms", "text", "truncated"] && PhoneNotificationJSON.integer($0["timestamp_ms"]) }),
              value.messages.allSatisfy({ $0.timestampMS >= 0 && Double($0.timestampMS) <= now.timeIntervalSince1970 * 1000 + 300_000 && $0.text.utf16.count <= 4000 }),
              ["ABSENT", "UNSUPPORTED", "UNAVAILABLE", "BITMAP_PREVIEW"].contains(value.imageState),
              (value.image != nil) == (value.imageState == "BITMAP_PREVIEW"),
              value.image != nil || value.messages.contains(where: { !$0.text.isEmpty }) else { throw PhoneNotificationError.invalid }
        if let image = value.image {
            guard let fields = object["image"] as? [String: Any], Set(fields.keys) == ["mime", "width", "height", "bytes", "sha256", "data_base64"],
                  ["width", "height", "bytes"].allSatisfy({ PhoneNotificationJSON.integer(fields[$0]) }),
                  image.mime == "image/png", (1...2048).contains(image.width), (1...2048).contains(image.height),
                  (8...1_048_576).contains(image.bytes), image.dataBase64.utf8.count <= 1_398_104,
                  let png = image.data, png.base64EncodedString() == image.dataBase64 else { throw PhoneNotificationError.invalid }
            let manifest = PhoneImageManifest(schema: 1, kind: "SHARED_IMAGE", id: UUID(),
                createdAtMS: Int64(now.timeIntervalSince1970 * 1000), filename: "mac-image-0.png", mime: image.mime,
                width: image.width, height: image.height, bytes: image.bytes, sha256: image.sha256)
            do { try manifest.validatePNG(png) } catch { throw PhoneNotificationError.invalid }
        } else if !(object["image"] is NSNull) { throw PhoneNotificationError.invalid }
        return value
    }
    /// Explicit null is part of the wire schema (synthesized Codable would omit a nil picture).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema); try c.encode(kind, forKey: .kind); try c.encode(capturedAtMS, forKey: .capturedAtMS)
        try c.encode(origin, forKey: .origin); try c.encode(installID, forKey: .installID); try c.encode(sourceKey, forKey: .sourceKey)
        try c.encode(title, forKey: .title); try c.encode(messages, forKey: .messages); try c.encode(truncated, forKey: .truncated)
        try c.encode(image, forKey: .image); try c.encode(imageState, forKey: .imageState)
        try c.encode(uriAttachments, forKey: .uriAttachments); try c.encode(complete, forKey: .complete)
    }
}

struct PhoneNotificationState: Decodable, Equatable {
    let schema: Int; let state: String; let recordedAtMS: Int64
    enum CodingKeys: String, CodingKey { case schema, state; case recordedAtMS = "recorded_at_ms" }
    static func parse(_ data: Data, now: Date = Date()) throws -> Self {
        let object = try PhoneNotificationJSON.object(data, maximum: 4096)
        guard Set(object.keys) == ["schema", "state", "recorded_at_ms"],
              PhoneNotificationJSON.integer(object["schema"]), PhoneNotificationJSON.integer(object["recorded_at_ms"]),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.schema == 1,
              ["OFF", "ACCESS_REQUIRED", "OTHER_APP_IGNORED", "MALFORMED", "SUMMARY_SKIPPED", "SOURCE_REQUIRED", "UNAVAILABLE", "URI_ONLY_UNSUPPORTED", "IMAGE_UNSUPPORTED", "NO_CONTENT", "SAVED", "CLEARED"].contains(value.state),
              Double(value.recordedAtMS) >= now.timeIntervalSince1970 * 1000 - 1_800_000,
              Double(value.recordedAtMS) <= now.timeIntervalSince1970 * 1000 + 300_000 else { throw PhoneNotificationError.invalid }
        return value
    }
}

enum PhoneNotificationStore {
    private static let writes = NSLock()
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Textem/NotificationPreviews", isDirectory: true)
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
    static func load(in directory: URL = directory) throws -> PhoneNotificationSnapshot? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }; try check(directory)
        let url = directory.appendingPathComponent("sample.json"); var info = stat()
        guard lstat(url.path, &info) == 0 else { if errno == ENOENT { return nil }; throw PhoneNotificationError.privateFile }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW); guard fd >= 0 else { throw PhoneNotificationError.privateFile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == getuid(),
              info.st_mode & mode_t(0o077) == 0, info.st_size >= 0, info.st_size <= PhoneNotificationSnapshot.maximumBytes else { throw PhoneNotificationError.privateFile }
        let data = try handle.read(upToCount: PhoneNotificationSnapshot.maximumBytes + 1) ?? Data()
        return try PhoneNotificationSnapshot.parse(data, requireFresh: false)
    }
    static func save(_ snapshot: PhoneNotificationSnapshot, in directory: URL = directory) throws {
        writes.lock(); defer { writes.unlock() }
        let data = try JSONEncoder().encode(snapshot); _ = try PhoneNotificationSnapshot.parse(data)
        try check(directory, create: true)
        let url = directory.appendingPathComponent("sample.json"); var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == getuid(), info.st_mode & mode_t(0o077) == 0 else { throw PhoneNotificationError.privateFile }
        } else if errno != ENOENT { throw PhoneNotificationError.privateFile }
        try data.write(to: url, options: .atomic); guard chmod(url.path, 0o600) == 0 else { throw PhoneNotificationError.privateFile }
    }
    static func clear(in directory: URL = directory) throws {
        writes.lock(); defer { writes.unlock() }; try check(directory)
        let url = directory.appendingPathComponent("sample.json"); var info = stat()
        if lstat(url.path, &info) != 0 { if errno == ENOENT { return }; throw PhoneNotificationError.privateFile }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == getuid(), info.st_mode & mode_t(0o077) == 0 else {
            throw PhoneNotificationError.privateFile
        }
        try FileManager.default.removeItem(at: url)
    }
}
