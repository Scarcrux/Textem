import Foundation
import Testing
@testable import scarcrux_textem

@Suite("Signed-app phone connection checks", .serialized) @MainActor
struct PhoneRecoveryCheckTests {
    @Test func connectionAndVisiblePaneAreSeparateClaimsWithoutContent() async throws {
        let pair = try CompanionConnectionTests().pairing()
        let sample = try PhoneNotificationTests().fixture(picture: true)
        let record = PhoneConversationStore.Record(accountKey: String(repeating: "1", count: 64),
            conversationKey: String(repeating: "2", count: 64), sourceKey: PhoneConversationStore.sourceKey(sample), samples: [sample])
        let result = await PhoneRecoveryCheck.collect(load: { pair }, fetch: { _ in .init(samples: [sample], dropped: 3) },
            records: { [record] })
        #expect(result.state == .connected && result.previews == 1 && result.pictures == 1 && result.dropped == 3)
        #expect(result.cacheReadable && result.savedConversations == 1 && result.matchingSavedSources == 1)
        #expect(!result.pane.visible && !result.pane.routeValidated)
        let text = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!text.contains(sample.title) && !text.contains(sample.sourceKey) && !text.contains(record.accountKey))
        #expect(!text.contains(String(repeating: "a", count: 64)) && !text.contains("image/png"))
    }
    @Test func missingDisconnectedAndKeychainFailureNeverFetch() async throws {
        let noFetch: @Sendable (CompanionPairing) async throws -> PhoneNotificationJournal = { _ in
            Issue.record("Unavailable credentials attempted a network transfer"); throw CompanionConnectionError.disconnected
        }
        let missing = await PhoneRecoveryCheck.collect(load: { nil }, fetch: noFetch, records: { [] })
        #expect(missing.state == .unpaired)
        let disconnected = await PhoneRecoveryCheck.collect(load: { Data() }, fetch: noFetch, records: { [] })
        #expect(disconnected.state == .disconnected)
        let failure = await PhoneRecoveryCheck.collect(load: { throw CompanionConnectionError.secureStorage }, fetch: noFetch, records: { [] })
        #expect(failure.state == .keychainUnavailable)
    }
    @Test func discoveryEvidenceRequiresPrivateEndpointAndFullPinVerification() async throws {
        let bytes = try CompanionConnectionTests().pairing(), pair = try CompanionPairing.parse(bytes)
        let sample = try PhoneNotificationTests().fixture()
        let result = await PhoneRecoveryCheck.collect(load: { bytes }, fetch: { _ in .init(samples: [sample], dropped: 0) }, records: { [] },
            discover: { _ in [.init(host: "8.8.8.8", port: 9443), .init(host: "192.168.1.3", port: 9443)] }, verifyDiscovered: { candidate in
                #expect(candidate.host == "192.168.1.3" && candidate.certificateSHA256 == pair.certificateSHA256 && candidate.token == pair.token)
                throw CompanionConnectionError.untrustedPhone
            })
        #expect(result.state == .connected && result.discoveryAttempted && result.discoveryCandidates == 2 && !result.verifiedDiscoveredEndpoint)
    }
    @Test func offlineCheckRetainsObservedPaneAndReportsNetworkFailure() async throws {
        let pair = try CompanionConnectionTests().pairing()
        let offline = await PhoneRecoveryCheck.collect(load: { pair }, fetch: { _ in throw URLError(.cannotConnectToHost) },
            records: { [] }, pane: { .init(visible: true, routeValidated: true, savedPreviews: 2, decodedPictures: 1) })
        #expect(offline.state == .unavailable && offline.previews == 0)
        #expect(offline.pane.visible && offline.pane.routeValidated && offline.pane.savedPreviews == 2)
        let pin = await PhoneRecoveryCheck.collect(load: { pair }, fetch: { _ in throw CompanionConnectionError.untrustedPhone }, records: { [] })
        #expect(pin.state == .untrustedPhone)
    }
    @Test func privateReportRefusesUnsafeLocations() async throws {
        let root = try PhoneImageTests().temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let reportDirectory = root.appendingPathComponent("report")
        try PhoneRecoveryCheck.save(.init(), in: reportDirectory)
        let file = reportDirectory.appendingPathComponent("phone-recovery-check.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: reportDirectory.path)
        #expect(throws: PhoneNotificationError.privateFile) { try PhoneRecoveryCheck.save(.init(), in: reportDirectory) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: reportDirectory)
        #expect(throws: PhoneNotificationError.privateFile) { try PhoneRecoveryCheck.save(.init(), in: link) }
    }
    @Test func offlineSavedLibraryEvidenceNeverClaimsLiveRouteOrRefresh() async throws {
        let pair = try CompanionConnectionTests().pairing()
        let result = await PhoneRecoveryCheck.collect(load: { pair }, fetch: { _ in throw URLError(.cannotConnectToHost) },
            records: { [] }, pane: { .init(visible: true, savedLibrary: true, accountValidated: true, savedPreviews: 2, decodedPictures: 1) })
        #expect(result.state == .unavailable && result.pane.savedLibrary && result.pane.accountValidated)
        #expect(result.pane.savedPreviews == 2 && !result.pane.routeValidated && result.pane.pairedRefreshAt == nil)
    }
    @Test func pairedRefreshEvidenceRequiresMatchingIngestAndIsClearedOnConnectionChange() async throws {
        let root = try PhoneImageTests().temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = PhoneImageConversation(accountID: UUID(), route: "synthetic-route", label: "Example")
        let sample = try PhoneNotificationTests().fixture()
        try PhoneConversationStore.link(sample, to: context, in: root)
        let model = PhoneConversationModel(context: context, directory: root, endpoint: { "" }, fetch: { _ in
            .init(samples: [sample], dropped: 0, transport: .pairedHTTPS)
        })
        model.validate = { _ in true }; await model.read()
        #expect(model.lastRefreshTransport == .pairedHTTPS && model.lastSuccessfulRefresh != nil && model.record?.samples == [sample])
        model.connectionChanged(); #expect(model.lastSuccessfulRefresh == nil && model.lastRefreshTransport == .unknown)
        let other = try PhoneConversationTests().fixture(changes: ["source_key": String(repeating: "b", count: 64)])
        let wrong = PhoneConversationModel(context: context, directory: root, endpoint: { "" }, fetch: { _ in
            .init(samples: [other], dropped: 0, transport: .pairedHTTPS)
        })
        wrong.validate = { _ in true }; await wrong.read()
        #expect(wrong.lastSuccessfulRefresh == nil && wrong.lastRefreshTransport == .unknown)
    }
    @Test func oneShotRequestsCannotSupplyCommandsOrEscapeThePrivatePath() throws {
        let root = try PhoneImageTests().temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(PhoneRecoveryCheck.requestName)
        try PhoneRecoveryCheck.requestBody.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try !PhoneRecoveryCheck.consumeRequest([root.appendingPathComponent("other.textemcheck").path], in: root))
        #expect(try !PhoneRecoveryCheck.consumeRequest([file.path, file.path], in: root))
        #expect(try PhoneRecoveryCheck.consumeRequest([file.path], in: root))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try Data("EXECUTE_SOMETHING_ELSE".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try !PhoneRecoveryCheck.consumeRequest([file.path], in: root))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(throws: PhoneImageError.privateFile) { try PhoneRecoveryCheck.consumeRequest([file.path], in: root) }
        try FileManager.default.removeItem(at: file)
        let target = root.appendingPathComponent("target")
        try PhoneRecoveryCheck.requestBody.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        #expect(throws: PhoneImageError.privateFile) { try PhoneRecoveryCheck.consumeRequest([file.path], in: root) }
    }
}
