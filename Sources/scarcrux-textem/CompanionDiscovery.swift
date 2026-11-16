import Darwin
import Foundation

struct CompanionEndpoint: Equatable, Sendable { let host: String; let port: Int }

/// DNS-SD locates candidates; only the existing full TLS pin authenticates them.
@MainActor final class CompanionDiscovery: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    static let serviceType = "_textem-phone._tcp."
    private let browser = NetServiceBrowser()
    private let prefix: String
    private var services: [NetService] = []
    private var endpoints: [CompanionEndpoint] = []
    private var continuation: CheckedContinuation<[CompanionEndpoint], Never>?
    private var deadline: Task<Void, Never>?
    private init(fingerprint: String) { prefix = "textem-" + fingerprint.prefix(12); super.init() }
    static func resolve(fingerprint: String) async -> [CompanionEndpoint] {
        guard fingerprint.utf8.count == 64, fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return [] }
        let lookup = CompanionDiscovery(fingerprint: fingerprint)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lookup.continuation = continuation
                if Task.isCancelled { lookup.finish(); return }
                lookup.browser.delegate = lookup
                lookup.browser.searchForServices(ofType: serviceType, inDomain: "local.")
                lookup.deadline = Task {
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    lookup.finish()
                }
            }
        } onCancel: { Task { @MainActor in lookup.finish() } }
    }
    private func finish() {
        guard let pending = continuation else { return }; continuation = nil
        deadline?.cancel(); browser.stop(); browser.delegate = nil
        for service in services { service.stop(); service.delegate = nil }
        pending.resume(returning: endpoints)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard continuation != nil, services.count < 8, service.name.lowercased().hasPrefix(prefix) else { return }
        services.append(service); service.delegate = self; service.resolve(withTimeout: 2)
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard continuation != nil, (1024...65535).contains(sender.port) else { return }
        for data in sender.addresses ?? [] {
            guard data.count >= MemoryLayout<sockaddr_in>.size else { continue }
            var address = data.withUnsafeBytes { $0.loadUnaligned(as: sockaddr_in.self) }
            guard address.sin_family == AF_INET else { continue }
            var characters = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address.sin_addr, &characters, socklen_t(characters.count)) != nil else { continue }
            let host = String(decoding: characters.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard CompanionPairing.privateAddress(host) else { continue }
            let endpoint = CompanionEndpoint(host: host, port: sender.port)
            if !endpoints.contains(endpoint), endpoints.count < 3 { endpoints.append(endpoint) }
        }
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) { finish() }
}

actor CompanionEndpointCache {
    static let shared = CompanionEndpointCache()
    private var values: [String: CompanionEndpoint] = [:]
    func get(_ pin: String) -> CompanionEndpoint? { values[pin] }
    func save(_ endpoint: CompanionEndpoint, pin: String) {
        if values.count >= 4 && values[pin] == nil { values.removeAll() }
        values[pin] = endpoint
    }
}

struct CompanionPairedJournalClient: Sendable {
    var network: @Sendable (CompanionPairing) async throws -> PhoneNotificationJournal = { try await CompanionHTTPSJournalClient().fetch(pairing: $0) }
    var discover: @Sendable (String) async -> [CompanionEndpoint] = { await CompanionDiscovery.resolve(fingerprint: $0) }
    var cache = CompanionEndpointCache.shared
    private func retryable(_ error: any Error) -> Bool {
        if let error = error as? URLError {
            return [.cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .notConnectedToInternet].contains(error.code)
        }
        return (error as? CompanionConnectionError) == .untrustedPhone
    }
    func fetch(pairing: CompanionPairing) async throws -> PhoneNotificationJournal {
        try Task.checkCancellation()
        let initial = await cache.get(pairing.certificateSHA256) ?? CompanionEndpoint(host: pairing.host, port: pairing.port)
        func request(_ endpoint: CompanionEndpoint) async throws -> PhoneNotificationJournal {
            guard CompanionPairing.privateAddress(endpoint.host), (1024...65535).contains(endpoint.port) else { throw CompanionConnectionError.invalidPairing }
            let candidate = CompanionPairing(host: endpoint.host, port: endpoint.port, certificateSHA256: pairing.certificateSHA256,
                token: pairing.token, installID: pairing.installID)
            return try await network(candidate)
        }
        do { return try await request(initial) }
        catch {
            guard retryable(error) else { throw error }
            let original = error
            let candidates = await discover(pairing.certificateSHA256)
            try Task.checkCancellation()
            for candidate in candidates.prefix(3) where candidate != initial {
                guard CompanionPairing.privateAddress(candidate.host), (1024...65535).contains(candidate.port) else { continue }
                do {
                    let result = try await request(candidate)
                    await cache.save(candidate, pin: pairing.certificateSHA256)
                    return result
                } catch { if !retryable(error) { throw error } }
            }
            throw original
        }
    }
}
