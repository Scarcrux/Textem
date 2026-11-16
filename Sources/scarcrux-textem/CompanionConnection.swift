import CryptoKit
import Foundation
import Security

enum CompanionConnectionError: Error, Equatable, LocalizedError {
    case invalidPairing, untrustedPhone, invalidReply, tooLarge, wrongPhone, disconnected, secureStorage
    var errorDescription: String? {
        switch self {
        case .invalidPairing: "This is not a valid Textem phone connection file."
        case .untrustedPhone: "The phone certificate does not match the paired phone."
        case .invalidReply: "The phone did not authorize this request or returned an invalid reply. Check that its connection and content capture are enabled."
        case .tooLarge: "The phone reply exceeds the preview size limit."
        case .wrongPhone: "The reply belongs to a different phone installation."
        case .disconnected: "Phone connection is disconnected. Import a phone connection file to reconnect."
        case .secureStorage: "Textem could not access its protected phone connection in Keychain."
        }
    }
}

/// Explicit pairing material. Never write this value to defaults, logs or a URL.
struct CompanionPairing: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let host: String
    let port: Int
    let certificateSHA256: String
    let token: String
    let installID: String
    var description: String { "CompanionPairing(<private>)" }
    var debugDescription: String { description }

    static func parse(_ data: Data) throws -> Self {
        let fields = try PhoneNotificationJSON.object(data, maximum: 4096)
        guard Set(fields.keys) == ["schema", "kind", "host", "port", "certificate_sha256", "token", "install_id"],
              PhoneNotificationJSON.integer(fields["schema"]), fields["schema"] as? Int == 1,
              fields["kind"] as? String == "TEXTEM_COMPANION_PAIRING",
              let host = fields["host"] as? String, privateAddress(host),
              PhoneNotificationJSON.integer(fields["port"]), let port = fields["port"] as? Int,
              (1024...65535).contains(port),
              let pin = fields["certificate_sha256"] as? String, hexKey(pin),
              let token = fields["token"] as? String, hexKey(token),
              let install = fields["install_id"] as? String,
              UUID(uuidString: install)?.uuidString.lowercased() == install else {
            throw CompanionConnectionError.invalidPairing
        }
        return Self(host: host, port: port, certificateSHA256: pin, token: token, installID: install)
    }
    private static func hexKey(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func privateAddress(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let numbers = parts.compactMap { UInt8($0) }
        guard numbers.count == 4, zip(parts, numbers).allSatisfy({ String($0.1) == $0.0 }) else { return false }
        return numbers[0] == 10 || (numbers[0] == 172 && (16...31).contains(numbers[1]))
            || (numbers[0] == 192 && numbers[1] == 168)
    }
    var endpoint: URL { URL(string: "https://\(host):\(port)/v1/journal")! }
}

/// Pin validation happens in TLS, before URLSession can transmit HTTP headers.
final class CompanionCertificatePolicy: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let fingerprint: String
    private let lock = NSLock()
    private var rejected = false
    var rejectedCertificate: Bool { lock.withLock { rejected } }
    init(fingerprint: String) { self.fingerprint = fingerprint }

    static func accepts(_ trust: SecTrust, fingerprint: String) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              chain.count == 1, let certificate = chain.first else { return false }
        let bytes = SecCertificateCopyData(certificate) as Data
        guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == fingerprint else { return false }
        // The explicitly paired leaf is the trust anchor. Hostnames/IPs can
        // change on a private LAN; identity comes from the out-of-band pin.
        guard SecTrustSetPolicies(trust, SecPolicyCreateBasicX509()) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        guard let trust = challenge.protectionSpace.serverTrust,
              Self.accepts(trust, fingerprint: fingerprint) else {
            lock.withLock { rejected = true }
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct CompanionHTTPSJournalClient: Sendable {
    static func validateReply(_ data: Data, response: HTTPURLResponse, requestID: UUID,
                              pairing: CompanionPairing) throws -> PhoneNotificationJournal {
        guard data.count <= PhoneNotificationJournal.maximumBytes else { throw CompanionConnectionError.tooLarge }
        guard response.statusCode == 200,
              response.value(forHTTPHeaderField: "X-Textem-Request-ID") == requestID.uuidString.lowercased(),
              response.mimeType == "application/json" else { throw CompanionConnectionError.invalidReply }
        let journal = try PhoneNotificationJournal.parse(data)
        guard journal.samples.allSatisfy({ $0.installID == pairing.installID }) else { throw CompanionConnectionError.wrongPhone }
        return journal
    }

    func fetch(pairing: CompanionPairing) async throws -> PhoneNotificationJournal {
        try Task.checkCancellation()
        let policy = CompanionCertificatePolicy(fingerprint: pairing.certificateSHA256)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        config.urlCredentialStorage = nil; config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15; config.tlsMinimumSupportedProtocolVersion = .TLSv12
        let session = URLSession(configuration: config, delegate: policy, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let id = UUID()
        var request = URLRequest(url: pairing.endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Bearer " + pairing.token, forHTTPHeaderField: "Authorization")
        request.setValue(id.uuidString.lowercased(), forHTTPHeaderField: "X-Textem-Request-ID")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw CompanionConnectionError.invalidReply }
            var data = Data()
            for try await byte in bytes {
                guard data.count < PhoneNotificationJournal.maximumBytes else { throw CompanionConnectionError.tooLarge }
                data.append(byte)
            }
            return try Self.validateReply(data, response: response, requestID: id, pairing: pairing)
        } catch {
            if policy.rejectedCertificate { throw CompanionConnectionError.untrustedPhone }
            throw error
        }
    }
}
