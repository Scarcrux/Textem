import AppKit
import CryptoKit
import Darwin
import Foundation
import ImageIO

enum PhoneImageError: String, LocalizedError {
    case invalid = "The phone image was refused: invalid metadata, PNG, size or digest."
    case privateFile = "The image library contains an unsafe file or directory."
    case full = "The image library is full. Remove an image before importing another."
    case adbMissing = "Android platform-tools (adb) is required for this local developer companion."
    case connection = "The developer connection failed. Unlock the phone, enable wireless debugging and check its current address."
    case noDevice = "No single authorized phone is connected. Enter its Wireless debugging IP address and port."
    case timeout = "The phone transfer timed out. No image was imported."
    case tlsRequired = "Use Android Wireless debugging (TLS), not legacy adb tcpip, for network transfers."
    case noExport = "No valid saved image is available. On the phone, Share → Textem Share Probe → Save image for Mac."
    var errorDescription: String? { rawValue }
}

struct PhoneImageManifest: Codable, Equatable, Sendable {
    let schema: Int
    let kind: String
    let id: UUID
    let createdAtMS: Int64
    let filename: String
    let mime: String
    let width: Int
    let height: Int
    let bytes: Int
    let sha256: String
    enum CodingKeys: String, CodingKey {
        case schema, kind, id, filename, mime, width, height, bytes, sha256
        case createdAtMS = "created_at_ms"
    }
    static let maximumBytes = 6 * 1024 * 1024
    static func parse(_ data: Data, now: Date = Date()) throws -> Self {
        guard data.count <= 4096,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["schema", "kind", "id", "created_at_ms", "filename", "mime", "width", "height", "bytes", "sha256"]),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.schema == 1,
              value.kind == "SHARED_IMAGE", ["mac-image-0.png", "mac-image-1.png"].contains(value.filename),
              value.mime == "image/png", (1...2048).contains(value.width), (1...2048).contains(value.height),
              (8...maximumBytes).contains(value.bytes),
              value.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              abs(now.timeIntervalSince1970 * 1000 - Double(value.createdAtMS)) <= 86_400_000,
              Double(value.createdAtMS) <= now.timeIntervalSince1970 * 1000 + 300_000 else { throw PhoneImageError.invalid }
        return value
    }
    func validatePNG(_ data: Data) throws {
        guard data.count == bytes, data.count <= Self.maximumBytes,
              data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              Self.digest(data) == sha256,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == width,
              properties[kCGImagePropertyPixelHeight] as? Int == height,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw PhoneImageError.invalid }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

struct ImportedPhoneImage: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let sourceID: UUID
    let importedAt: Date
    let width: Int
    let height: Int
    let bytes: Int
    let sha256: String
    var filename: String { id.uuidString + ".png" }
}

enum PhoneImageStore {
    private static let writes = NSRecursiveLock()
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Textem/PhoneImages", isDirectory: true)
    }
    private struct Index: Codable { let schema: Int; let images: [ImportedPhoneImage] }
    private static func checkDirectory(_ directory: URL, create: Bool = false) throws {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT, create else { throw PhoneImageError.privateFile }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            guard lstat(directory.path, &info) == 0 else { throw PhoneImageError.privateFile }
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == getuid(),
              info.st_mode & mode_t(0o077) == 0 else { throw PhoneImageError.privateFile }
    }
    static func readPrivate(_ url: URL, maximum: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw PhoneImageError.privateFile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == getuid(), info.st_mode & mode_t(0o077) == 0,
              info.st_size >= 0, info.st_size <= maximum else { throw PhoneImageError.privateFile }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw PhoneImageError.invalid }
        return data
    }
    static func load(in directory: URL = directory) throws -> [ImportedPhoneImage] {
        var info = stat()
        if lstat(directory.path, &info) != 0 && errno == ENOENT { return [] }
        try checkDirectory(directory)
        let indexURL = directory.appendingPathComponent("index.json")
        if lstat(indexURL.path, &info) != 0 && errno == ENOENT { return [] }
        let data = try readPrivate(indexURL, maximum: 128 * 1024)
        guard let index = try? JSONDecoder().decode(Index.self, from: data), index.schema == 1,
              index.images.count <= 25, Set(index.images.map(\.id)).count == index.images.count,
              Set(index.images.map(\.sourceID)).count == index.images.count,
              index.images.allSatisfy({ (1...2048).contains($0.width) && (1...2048).contains($0.height)
                  && (8...PhoneImageManifest.maximumBytes).contains($0.bytes)
                  && $0.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }),
              index.images.reduce(0, { $0 + $1.bytes }) <= 100 * 1024 * 1024 else { throw PhoneImageError.invalid }
        return index.images
    }
    private static func writeIndex(_ images: [ImportedPhoneImage], in directory: URL) throws {
        let url = directory.appendingPathComponent("index.json")
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == getuid(),
                  info.st_mode & mode_t(0o077) == 0 else { throw PhoneImageError.privateFile }
        }
        let data = try JSONEncoder().encode(Index(schema: 1, images: images))
        try data.write(to: url, options: .atomic)
        guard chmod(url.path, 0o600) == 0 else { throw PhoneImageError.privateFile }
    }
    @discardableResult
    static func importImage(manifest: PhoneImageManifest, png: Data, in directory: URL = directory) throws -> ImportedPhoneImage {
        writes.lock(); defer { writes.unlock() }
        // Revalidate even when invoked directly, not only by the adb transport.
        _ = try PhoneImageManifest.parse(JSONEncoder().encode(manifest))
        try manifest.validatePNG(png)
        try checkDirectory(directory, create: true)
        var images = try load(in: directory)
        if let existing = images.first(where: { $0.sha256 == manifest.sha256 }) {
            _ = try imageData(existing, in: directory); return existing
        }
        guard !images.contains(where: { $0.sourceID == manifest.id }) else { throw PhoneImageError.invalid }
        guard images.count < 25, images.reduce(0, { $0 + $1.bytes }) + png.count <= 100 * 1024 * 1024 else { throw PhoneImageError.full }
        let image = ImportedPhoneImage(id: UUID(), sourceID: manifest.id, importedAt: Date(), width: manifest.width,
            height: manifest.height, bytes: manifest.bytes, sha256: manifest.sha256)
        let url = directory.appendingPathComponent(image.filename)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw PhoneImageError.privateFile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: png); try handle.synchronize(); try handle.close()
            images.insert(image, at: 0); try writeIndex(images, in: directory)
        } catch { try? handle.close(); try? FileManager.default.removeItem(at: url); throw error }
        return image
    }
    static func imageData(_ image: ImportedPhoneImage, in directory: URL = directory) throws -> Data {
        try checkDirectory(directory)
        let data = try readPrivate(directory.appendingPathComponent(image.filename), maximum: PhoneImageManifest.maximumBytes)
        let manifest = PhoneImageManifest(schema: 1, kind: "SHARED_IMAGE", id: image.sourceID,
            createdAtMS: Int64(Date().timeIntervalSince1970 * 1000), filename: "mac-image-0.png", mime: "image/png",
            width: image.width, height: image.height, bytes: image.bytes, sha256: image.sha256)
        try manifest.validatePNG(data); return data
    }
    static func remove(_ image: ImportedPhoneImage, in directory: URL = directory) throws {
        writes.lock(); defer { writes.unlock() }
        var images = try load(in: directory)
        guard images.contains(image) else { throw PhoneImageError.invalid }
        images.removeAll { $0.id == image.id }; try writeIndex(images, in: directory)
        try FileManager.default.removeItem(at: directory.appendingPathComponent(image.filename))
    }
}
