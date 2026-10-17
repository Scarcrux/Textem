import Foundation
import Darwin

// Counts and fixed event labels only. No sender, body, thread ID or error text.
// Unlike NSLog/stderr, this survives normal LaunchServices launches.
@MainActor
enum NotificationDiagnostics {
    static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Textem/notifications.jsonl")

    static func record(_ event: String, values: [String: Int] = [:]) {
        try? append(event, values: values, to: url)
    }

    static func append(_ event: String, values: [String: Int], to url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        // Bounded local history; only truncate after checking ownership/type.
        if info.st_size > 262_144 { _ = ftruncate(fd, 0) }
        var record: [String: Any] = values
        record["event"] = event
        record["at"] = ISO8601DateFormatter().string(from: Date())
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        data.append(10)
        let written = data.withUnsafeBytes { bytes in
            write(fd, bytes.baseAddress, bytes.count)
        }
        guard written == data.count else { throw CocoaError(.fileWriteUnknown) }
    }
}
