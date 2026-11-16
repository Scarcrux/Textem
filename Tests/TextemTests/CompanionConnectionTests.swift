import CryptoKit
import Foundation
import Security
import Testing
import AppKit
import SwiftUI
@testable import scarcrux_textem

@Suite("Paired companion transport", .serialized) @MainActor
struct CompanionConnectionTests {
    let install = "57b2dd91-cfa8-4193-9a38-e2d6d6470625"
    let token = String(repeating: "a", count: 64)
    func pairing(_ changes: [String: Any] = [:]) throws -> Data {
        var fields: [String: Any] = ["schema": 1, "kind": "TEXTEM_COMPANION_PAIRING", "host": "192.168.1.2", "port": 9443,
            "certificate_sha256": String(repeating: "b", count: 64), "token": token, "install_id": install]
        fields.merge(changes, uniquingKeysWith: { _, new in new })
        return try JSONSerialization.data(withJSONObject: fields)
    }
    @Test func pairingIsExplicitPrivateAndStrict() throws {
        let good = try CompanionPairing.parse(pairing())
        #expect(!String(reflecting: good).contains(token))
        #expect(good.endpoint.absoluteString == "https://192.168.1.2:9443/v1/journal")
        for (field, bad): (String, Any) in [("schema", true), ("host", "127.0.0.1"), ("host", "8.8.8.8"),
            ("host", "192.168.01.2"), ("host", "user@192.168.1.2"), ("host", "192.168.1.2/path"),
            ("host", "example.com"), ("port", true), ("port", 80), ("port", 65536), ("token", "short"),
            ("certificate_sha256", String(repeating: "B", count: 64)), ("install_id", "bad"), ("extra", 1)] {
            #expect(throws: (any Error).self) { try CompanionPairing.parse(pairing([field: bad])) }
        }
        let raw = String(decoding: try pairing(), as: UTF8.self)
        #expect(throws: (any Error).self) { try CompanionPairing.parse(Data(("{\"schema\":1," + raw.dropFirst()).utf8)) }
    }
    @Test func replyBindsRequestAndPhoneAndRefusesSynthetic() throws {
        let pair = try CompanionPairing.parse(pairing()), id = UUID()
        let sample = try PhoneNotificationTests().fixture()
        let bytes = try PhoneConversationTests().journal([sample])
        func response(_ request: UUID = id, status: Int = 200) -> HTTPURLResponse {
            HTTPURLResponse(url: pair.endpoint, statusCode: status, httpVersion: "HTTP/1.1", headerFields:
                ["Content-Type": "application/json", "X-Textem-Request-ID": request.uuidString.lowercased()])!
        }
        #expect(try CompanionHTTPSJournalClient.validateReply(bytes, response: response(), requestID: id, pairing: pair).samples == [sample])
        #expect(throws: CompanionConnectionError.invalidReply) {
            try CompanionHTTPSJournalClient.validateReply(bytes, response: response(UUID()), requestID: id, pairing: pair)
        }
        #expect(throws: CompanionConnectionError.invalidReply) {
            try CompanionHTTPSJournalClient.validateReply(bytes, response: response(status: 403), requestID: id, pairing: pair)
        }
        let other = CompanionPairing(host: pair.host, port: pair.port, certificateSHA256: pair.certificateSHA256, token: pair.token, installID: UUID().uuidString.lowercased())
        #expect(throws: CompanionConnectionError.wrongPhone) {
            try CompanionHTTPSJournalClient.validateReply(bytes, response: response(), requestID: id, pairing: other)
        }
        let synthetic = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "NOTIFICATION_JOURNAL", with: "SYNTHETIC_NOTIFICATION_JOURNAL").utf8)
        #expect(throws: (any Error).self) { try CompanionHTTPSJournalClient.validateReply(synthetic, response: response(), requestID: id, pairing: pair) }
        #expect(throws: CompanionConnectionError.tooLarge) {
            try CompanionHTTPSJournalClient.validateReply(Data(repeating: 0, count: PhoneNotificationJournal.maximumBytes + 1), response: response(), requestID: id, pairing: pair)
        }
    }

    @Test func realTLSAcceptsOnlyPairedCertificateAndAuthorizedMac() async throws {
        let root = try PhoneImageTests().temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let cert = root.appendingPathComponent("certificate.pem"), key = root.appendingPathComponent("key.pem")
        let der = root.appendingPathComponent("certificate.der")
        try run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=TextemFixture",
            "-keyout", key.path, "-out", cert.path])
        try run("/usr/bin/openssl", ["x509", "-in", cert.path, "-outform", "DER", "-out", der.path])
        let certData = try Data(contentsOf: der)
        let pin = SHA256.hash(data: certData).map { String(format: "%02x", $0) }.joined()
        let certificate = try #require(SecCertificateCreateWithData(nil, certData as CFData))
        var directTrust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &directTrust) == errSecSuccess)
        #expect(CompanionCertificatePolicy.accepts(try #require(directTrust), fingerprint: pin))
        #expect(SecTrustSetVerifyDate(try #require(directTrust), Date().addingTimeInterval(3 * 86400) as CFDate) == errSecSuccess)
        #expect(!CompanionCertificatePolicy.accepts(try #require(directTrust), fingerprint: pin))
        #expect(SecTrustSetVerifyDate(try #require(directTrust), Date().addingTimeInterval(-3 * 86400) as CFDate) == errSecSuccess)
        #expect(!CompanionCertificatePolicy.accepts(try #require(directTrust), fingerprint: pin))
        let sample = try PhoneNotificationTests().fixture()
        let payload = try PhoneConversationTests().journal([sample])
        let script = """
        import ssl, socket, sys, base64
        ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version=ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(sys.argv[1],sys.argv[2])
        listener=socket.socket(); listener.bind(('127.0.0.1',0)); listener.listen(1); listener.settimeout(10)
        print(listener.getsockname()[1],flush=True)
        requests=0; payloads=0
        try:
          raw,_=listener.accept(); raw.settimeout(5)
          with ctx.wrap_socket(raw,server_side=True) as conn:
            data=b''
            while b'\\r\\n\\r\\n' not in data and len(data)<=4096:
              part=conn.recv(1024)
              if not part: break
              data+=part
            requests+=1
            lines=data.decode('ascii').split('\\r\\n')
            headers={k.strip().lower():v.strip() for k,v in (line.split(':',1) for line in lines[1:] if ':' in line)}
            valid=headers.get('authorization')=='Bearer '+sys.argv[3]
            body=base64.b64decode(sys.argv[4]) if valid else b''
            payloads+=int(valid)
            code='200 OK' if valid else '403 Forbidden'
            response=('HTTP/1.1 '+code+'\\r\\nContent-Type: application/json\\r\\nX-Textem-Request-ID: '+headers.get('x-textem-request-id','')+'\\r\\nContent-Length: '+str(len(body))+'\\r\\nConnection: close\\r\\n\\r\\n').encode('ascii')
            conn.sendall(response+body)
        except (ssl.SSLError, OSError): pass
        finally:
          listener.close(); print(str(requests)+' '+str(payloads),flush=True)
        """
        for mode in ["paired", "wrong-pin", "wrong-token"] {
            let server = Process(), output = Pipe()
            server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            server.arguments = ["-c", script, cert.path, key.path, token, payload.base64EncodedString()]
            server.standardOutput = output; server.standardError = FileHandle.nullDevice
            try server.run()
            defer { if server.isRunning { server.terminate() }; try? output.fileHandleForReading.close() }
            var line = Data()
            while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([10]) { line.append(byte) }
            let port = try #require(Int(String(decoding: line, as: UTF8.self)))
            // Loopback is constructed only by this fixture; pairing-file parsing
            // refuses it, so no production discovery/credential state is used.
            let pair = CompanionPairing(host: "127.0.0.1", port: port,
                certificateSHA256: mode == "wrong-pin" ? String(repeating: "0", count: 64) : pin,
                token: mode == "wrong-token" ? String(repeating: "c", count: 64) : token, installID: install)
            if mode == "paired" {
                #expect(try await CompanionHTTPSJournalClient().fetch(pairing: pair).samples == [sample])
            } else if mode == "wrong-pin" {
                await #expect(throws: CompanionConnectionError.untrustedPhone) { try await CompanionHTTPSJournalClient().fetch(pairing: pair) }
            } else {
                await #expect(throws: (any Error).self) { try await CompanionHTTPSJournalClient().fetch(pairing: pair) }
            }
            server.waitUntilExit()
            let counts = String(decoding: try output.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(counts == (mode == "paired" ? "1 1" : mode == "wrong-pin" ? "0 0" : "1 0"))
        }
    }
    private func run(_ tool: String, _ args: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: tool); process.arguments = args
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); #expect(process.terminationStatus == 0)
    }

    @Test func pairingChangeOrDisconnectCannotPublishOrFallBack() async throws {
        final class State: @unchecked Sendable {
            let lock = NSLock(); var value: Data?
            init(_ value: Data?) { self.value = value }
            func load() -> Data? { lock.withLock { value } }
            func save(_ data: Data?) { lock.withLock { value = data } }
        }
        let bytes = try pairing(), state = State(try pairing())
        let journal = PhoneNotificationJournal(samples: [try PhoneNotificationTests().fixture()], dropped: 0)
        let good = CompanionJournalTransport(load: { state.load() }, network: { _ in journal }, developer: { _ in
            Issue.record("Paired connection silently fell back to ADB"); throw CompanionConnectionError.disconnected
        })
        #expect(try await good.fetch(developerEndpoint: "").samples == journal.samples)
        let revoked = CompanionJournalTransport(load: { state.load() }, network: { _ in state.save(Data()); return journal }, developer: good.developer)
        await #expect(throws: CompanionConnectionError.disconnected) { try await revoked.fetch(developerEndpoint: "") }
        await #expect(throws: CompanionConnectionError.disconnected) { try await good.fetch(developerEndpoint: "") }
        state.save(bytes)
        let failed = CompanionJournalTransport(load: good.load, network: { _ in throw CompanionConnectionError.invalidReply }, developer: good.developer)
        await #expect(throws: CompanionConnectionError.invalidReply) { try await failed.fetch(developerEndpoint: "") }
        state.save(Data("invalid".utf8))
        await #expect(throws: (any Error).self) { try await good.fetch(developerEndpoint: "") }
    }

    @Test func connectionUIStoresOnlyValidatedMaterialAndRetainsDisconnect() throws {
        var saved: Data?
        let model = CompanionConnectionModel(load: { saved }, save: { saved = $0 })
        #expect(!model.paired)
        #expect(throws: (any Error).self) { try model.importData(Data("invalid".utf8)) }
        #expect(saved == nil)
        try model.importData(pairing()); #expect(model.paired && saved != nil && !model.status.contains(token))
        let view = NSHostingView(rootView: CompanionConnectionView(model: model, onChanged: {}, onClose: {}))
        view.frame = NSRect(x: 0, y: 0, width: 588, height: 410); view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        try model.disconnect(); #expect(!model.paired && saved == Data())
        let reopened = CompanionConnectionModel(load: { saved }, save: { saved = $0 })
        #expect(!reopened.paired && reopened.status.contains("disconnected"))
        let failing = CompanionConnectionModel(load: { try pairing() }, save: { _ in throw CompanionConnectionError.secureStorage })
        #expect(throws: CompanionConnectionError.secureStorage) { try failing.disconnect() }
        #expect(failing.paired && failing.status.contains("Couldn’t disconnect"))
    }
}
