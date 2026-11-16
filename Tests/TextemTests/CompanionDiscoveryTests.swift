import Foundation
import Testing
@testable import scarcrux_textem

@Suite("Pinned phone rediscovery", .serialized) @MainActor
struct CompanionDiscoveryTests {
    @Test func platformServiceNameAndPeerDeclarationsAgree() throws {
        let type = CompanionDiscovery.serviceType
        let label = try #require(type.split(separator: ".").first).dropFirst()
        #expect((1...15).contains(label.count))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("Resources/Info.plist")), format: nil) as? [String: Any])
        #expect((plist["NSBonjourServices"] as? [String])?.contains(String(type.dropLast())) == true)
        let java = try String(contentsOf: root.appendingPathComponent("Experiments/AndroidProbe/app/src/main/java/dev/textem/probe/CompanionServer.java"), encoding: .utf8)
        #expect(java.contains("SERVICE_TYPE = \"" + type + "\""))
    }
    actor Calls {
        var hosts: [String] = []
        func record(_ host: String) { hosts.append(host) }
        func values() -> [String] { hosts }
    }
    @Test func addressChangeKeepsCredentialsAndCachesOnlyAPinnedSuccess() async throws {
        let pair = try CompanionPairing.parse(CompanionConnectionTests().pairing())
        let sample = try PhoneNotificationTests().fixture()
        let calls = Calls(), cache = CompanionEndpointCache()
        let client = CompanionPairedJournalClient(network: { candidate in
            await calls.record(candidate.host)
            #expect(candidate.token == pair.token && candidate.certificateSHA256 == pair.certificateSHA256 && candidate.installID == pair.installID)
            guard candidate.host == "192.168.1.3" else { throw URLError(.cannotConnectToHost) }
            return .init(samples: [sample], dropped: 0)
        }, discover: { pin in
            #expect(pin == pair.certificateSHA256)
            return [.init(host: "8.8.8.8", port: 9443), .init(host: "192.168.1.3", port: 9443)]
        }, cache: cache)
        #expect(try await client.fetch(pairing: pair).samples == [sample])
        #expect(try await client.fetch(pairing: pair).samples == [sample])
        #expect(await calls.values() == [pair.host, "192.168.1.3", "192.168.1.3"])
    }
    @Test func forgedServicesNeverReplacePinOrSuppressAnAuthenticationFailure() async throws {
        let pair = try CompanionPairing.parse(CompanionConnectionTests().pairing())
        let calls = Calls(), cache = CompanionEndpointCache()
        let client = CompanionPairedJournalClient(network: { candidate in
            await calls.record(candidate.host)
            #expect(candidate.certificateSHA256 == pair.certificateSHA256 && candidate.token == pair.token)
            throw CompanionConnectionError.untrustedPhone
        }, discover: { _ in [.init(host: "192.168.1.4", port: 9443), .init(host: "8.8.8.8", port: 9443)] }, cache: cache)
        await #expect(throws: CompanionConnectionError.untrustedPhone) { try await client.fetch(pairing: pair) }
        #expect(await calls.values() == [pair.host, "192.168.1.4"])
        #expect(await cache.get(pair.certificateSHA256) == nil)
    }
    @Test func invalidPayloadIsNotAnAddressChangeAndCancellationNeverStartsDiscovery() async throws {
        let pair = try CompanionPairing.parse(CompanionConnectionTests().pairing())
        let client = CompanionPairedJournalClient(network: { _ in throw CompanionConnectionError.wrongPhone }, discover: { _ in
            Issue.record("Identity failure triggered discovery"); return []
        }, cache: CompanionEndpointCache())
        await #expect(throws: CompanionConnectionError.wrongPhone) { try await client.fetch(pairing: pair) }
        #expect(await CompanionDiscovery.resolve(fingerprint: "invalid").isEmpty)
        let cancelled = CompanionPairedJournalClient(network: { _ in
            Issue.record("Cancelled check attempted a network request"); throw CompanionConnectionError.invalidReply
        }, discover: { _ in Issue.record("Cancelled check attempted discovery"); return [] }, cache: CompanionEndpointCache())
        let task = Task { try await cancelled.fetch(pairing: pair) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
