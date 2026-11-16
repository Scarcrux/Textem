import Darwin
import Foundation

/// Runs inside signed Textem: CLI helpers cannot establish its Keychain access.
enum PhoneRecoveryCheck {
    enum State: String, Codable {
        case connected, unpaired, disconnected, keychainUnavailable, invalidPairing, untrustedPhone, invalidReply, unavailable, cancelled
        var message: String {
            switch self {
            case .connected: "Phone connection working."
            case .unpaired: "No phone connection has been imported."
            case .disconnected: "The phone connection is disconnected on this Mac."
            case .keychainUnavailable: "Textem couldn’t read its protected phone connection from Keychain."
            case .invalidPairing: "The saved phone connection is invalid. Import its connection file again."
            case .untrustedPhone: "The phone certificate does not match the paired phone."
            case .invalidReply: "The phone reply failed identity or format validation."
            case .unavailable: "Couldn’t reach the paired phone over local Wi-Fi."
            case .cancelled: "The connection check was cancelled."
            }
        }
    }
    struct Pane: Codable, Sendable {
        var visible = false
        var routeValidated = false
        var savedPreviews = 0
        var decodedPictures = 0
        var pairedRefreshAt: Date?
    }
    struct Report: Encodable, Sendable {
        let schema = 1
        let kind = "PHONE_RECOVERY_CHECK"
        var checkedAt = Date()
        var state: State = .unavailable
        var previews = 0
        var sources = 0
        var pictures = 0
        var unresolvedMedia = 0
        var dropped = 0
        var cacheReadable = false
        var savedConversations = 0
        var matchingSavedSources = 0
        var discoveryAttempted = false
        var discoveryCandidates = 0
        var verifiedDiscoveredEndpoint = false
        var pane = Pane()
    }
    @MainActor static func collect(
        load: @Sendable () throws -> Data? = { try CompanionCredentialStore().load() },
        fetch: @Sendable (CompanionPairing) async throws -> PhoneNotificationJournal = { try await CompanionPairedJournalClient().fetch(pairing: $0) },
        records: @Sendable () throws -> [PhoneConversationStore.Record] = { try PhoneConversationStore.load() },
        discover: (@Sendable (String) async -> [CompanionEndpoint])? = nil,
        verifyDiscovered: @Sendable (CompanionPairing) async throws -> Void = { _ = try await CompanionHTTPSJournalClient().fetch(pairing: $0) },
        pane: @MainActor () async -> Pane = { Pane() }
    ) async -> Report {
        var report = Report()
        report.pane = await pane()
        let stored = try? records()
        if let stored { report.cacheReadable = true; report.savedConversations = stored.count }
        do {
            let saved: Data?
            do { saved = try load() } catch { report.state = .keychainUnavailable; return report }
            guard let saved else { report.state = .unpaired; return report }
            guard !saved.isEmpty else { report.state = .disconnected; return report }
            let pair = try CompanionPairing.parse(saved)
            let journal = try await fetch(pair)
            try Task.checkCancellation()
            guard try load() == saved else { report.state = .disconnected; return report }
            report.state = .connected
            report.previews = journal.samples.count
            report.sources = Set(journal.samples.map(\.sourceKey)).count
            report.pictures = journal.samples.filter { $0.image != nil }.count
            report.unresolvedMedia = journal.samples.reduce(0) { $0 + $1.uriAttachments }
            report.dropped = journal.dropped
            if let stored {
                let keys = Set(journal.samples.map(PhoneConversationStore.sourceKey))
                report.matchingSavedSources = stored.filter { keys.contains($0.sourceKey) }.count
            }
            if let discover {
                report.discoveryAttempted = true
                let candidates = Array((await discover(pair.certificateSHA256)).prefix(3))
                report.discoveryCandidates = candidates.count
                for endpoint in candidates {
                    try Task.checkCancellation()
                    guard CompanionPairing.privateAddress(endpoint.host), (1024...65535).contains(endpoint.port) else { continue }
                    let candidate = CompanionPairing(host: endpoint.host, port: endpoint.port, certificateSHA256: pair.certificateSHA256,
                        token: pair.token, installID: pair.installID)
                    do { try await verifyDiscovered(candidate); report.verifiedDiscoveredEndpoint = true; break }
                    catch { continue }
                }
            }
            try Task.checkCancellation()
            guard try load() == saved else { report.state = .disconnected; return report }
        } catch is CancellationError { report.state = .cancelled
        } catch CompanionConnectionError.secureStorage { report.state = .keychainUnavailable
        } catch CompanionConnectionError.invalidPairing { report.state = .invalidPairing
        } catch CompanionConnectionError.untrustedPhone { report.state = .untrustedPhone
        } catch is CompanionConnectionError { report.state = .invalidReply
        } catch is PhoneNotificationError { report.state = .invalidReply
        } catch { report.state = .unavailable }
        report.pane = await pane()
        return report
    }
    static var directory: URL {
        PhoneConversationStore.directory.deletingLastPathComponent().appendingPathComponent("Diagnostics")
    }
    static let requestName = "phone-connection.textemcheck"
    static let requestBody = Data("TEXTEM_PHONE_CONNECTION_CHECK\n".utf8)
    static func consumeRequest(_ filenames: [String], in directory: URL = directory) throws -> Bool {
        guard filenames.count == 1 else { return false }
        let expected = directory.appendingPathComponent(requestName)
        guard URL(fileURLWithPath: filenames[0]).standardizedFileURL == expected.standardizedFileURL else { return false }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw PhoneNotificationError.privateFile }
        let data = try PhoneImageStore.readPrivate(expected, maximum: 128)
        guard data == requestBody else { return false }
        try FileManager.default.removeItem(at: expected)
        return true
    }
    static func save(_ report: Report, in directory: URL = directory) throws {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw PhoneNotificationError.privateFile }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw PhoneNotificationError.privateFile }
        let file = directory.appendingPathComponent("phone-recovery-check.json")
        if lstat(file.path, &info) == 0 { _ = try PhoneImageStore.readPrivate(file, maximum: 4096) }
        else if errno != ENOENT { throw PhoneNotificationError.privateFile }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(report)
        guard data.count <= 4096 else { throw PhoneNotificationError.invalid }
        try data.write(to: file, options: .atomic)
        guard chmod(file.path, 0o600) == 0 else { throw PhoneNotificationError.privateFile }
    }
}
