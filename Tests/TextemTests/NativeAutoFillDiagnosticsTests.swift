import Foundation
import Testing
import NativeAutoFillCore
@preconcurrency import AuthenticationServices
@testable import scarcrux_textem

@Suite("Private native AutoFill readiness") @MainActor
struct NativeAutoFillDiagnosticsTests {
    @Test func boundedPrivateMetadataSchemaAndSymlinkRefusal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("textem-readiness-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("readiness.jsonl")
        try NativeAutoFillDiagnostics.append(.ready, .init(capture: 7, provider: 1, sources: 90, eligible: -5, indexed: 99, withheld: -2), to: log)
        let data = try Data(contentsOf: log)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["at", "event", "capture", "provider", "sources", "eligible", "indexed", "withheld", "failure", "process"])
        #expect(object["event"] as? String == "ready" && object["sources"] as? Int == 16 && object["eligible"] as? Int == 0)
        #expect(object["capture"] as? Int == 1 && object["provider"] as? Int == 1)
        #expect(object["indexed"] as? Int == 16 && object["withheld"] as? Int == 0)
        #expect(try FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as? Int == 0o600)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: log)
        #expect(throws: (any Error).self) { try NativeAutoFillDiagnostics.append(.vaultRefused, .init(), to: link) }
        #expect(try Data(contentsOf: log) == data)
    }

    @Test func realCoordinatorDiscriminatesReadyDisabledLockedAndUnavailable() async throws {
        let storage = NativeCodeVaultTests.Storage()
        let publisher = NativeCodeVaultTests.Publisher()
        var events: [(NativeAutoFillDiagnostics.Event, NativeAutoFillDiagnostics.Counts)] = []
        let model = NativeAutoFillCoordinator(vault: CodeVault(storage: storage), publisher: publisher,
            available: true, accountExists: { _ in false }, diagnose: { events.append(($0, $1)) })
        await model.setEnabled(true)
        #expect(events.last?.0 == .ready && events.last?.1.capture == 1 && events.last?.1.provider == 1)
        publisher.failure = NativeCodeSetupError.notEnabled
        await model.synchronize()
        #expect(events.last?.0 == .providerDisabled && events.last?.1.provider == 0)
        publisher.failure = NSError(domain: "SyntheticPublisher", code: 8)
        await model.synchronize()
        #expect(events.last?.0 == .publicationRefused && events.last?.1.failure == 8)
        publisher.failure = NativeCodeSetupError.indexReadbackRefused
        await model.synchronize()
        #expect(events.last?.0 == .publicationRefused && events.last?.1.provider == 0 && events.last?.1.indexed == 0)
        #expect(model.status.contains("didn’t confirm the AutoFill update"))
        storage.locked = true
        await model.synchronize()
        #expect(events.last?.0 == .vaultRefused && events.last?.1.failure == -25308)
        let count = events.count
        let unavailable = NativeAutoFillCoordinator(vault: CodeVault(storage: storage), publisher: publisher,
            available: false, accountExists: { _ in false }, diagnose: { events.append(($0, $1)) })
        unavailable.start()
        #expect(events.count == count + 1 && events.last?.0 == .runtimeUnavailable)
        storage.locked = false; publisher.failure = nil
        await model.setEnabled(false)
        #expect(events.last?.0 == .ready && events.last?.1.capture == 0)
    }
    @Test func nativeIdentityReadbackDiscriminatesMissingWrongAndDuplicateRows() throws {
        guard #available(macOS 15, *) else { return }
        let now = Date()
        let sample = try #require(CodeSample(message: "@example.com #004321", accountID: UUID(), receivedAt: now, consent: true))
        let entries = CodeIndexEntry.project([sample], now: now)
        let entry = try #require(entries.first)
        func identity(domain: String = "example.com", label: String? = nil, record: String? = nil,
                      type: ASCredentialServiceIdentifier.IdentifierType = .domain) -> ASOneTimeCodeCredentialIdentity {
            ASOneTimeCodeCredentialIdentity(serviceIdentifier: .init(identifier: domain, type: type),
                label: label ?? entry.label, recordIdentifier: record ?? entry.recordID)
        }
        #expect(NativeCodeIndexReadback.matches([identity()], expected: entries))
        #expect(NativeCodeIndexReadback.matches([], expected: []))
        for actual: [any ASCredentialIdentity] in [[], [identity(), identity()], [identity(domain: "other.example")],
                [identity(label: "Wrong label")], [identity(record: UUID().uuidString)], [identity(type: .URL)],
                [ASPasswordCredentialIdentity(serviceIdentifier: .init(identifier: "example.com", type: .domain), user: "Synthetic", recordIdentifier: entry.recordID)]] {
            #expect(!NativeCodeIndexReadback.matches(actual, expected: entries))
        }
        #expect(!NativeCodeIndexReadback.matches([identity()], expected: []))
    }
    @Test func publishedAndWithheldCountsExplainTheRealAmbiguityGate() async throws {
        let storage = NativeCodeVaultTests.Storage(); let vault = CodeVault(storage: storage)
        let publisher = NativeCodeVaultTests.Publisher(); let account = UUID(); let now = Date()
        let source = try #require(NotificationCodeSource(installationID: UUID().uuidString, shortcutKey: String(repeating: "a", count: 64)))
        try vault.enable(); try vault.bind(source, to: account)
        try vault.ingest(source: source, origin: "POSTED", message: "@example.com #004321", timestamp: now, now: now)
        var events: [NativeAutoFillDiagnostics.Counts] = []
        let model = NativeAutoFillCoordinator(vault: vault, publisher: publisher, available: true,
            clock: { now.addingTimeInterval(2) }, accountExists: { $0 == account }, diagnose: { _, counts in events.append(counts) })
        await model.synchronize()
        #expect(events.last?.eligible == 1 && events.last?.indexed == 1 && events.last?.withheld == 0)
        try vault.ingest(source: source, origin: "POSTED", message: "@example.com #004321", timestamp: now.addingTimeInterval(1), now: now.addingTimeInterval(1))
        await model.synchronize()
        #expect(events.last?.eligible == 2 && events.last?.indexed == 0 && events.last?.withheld == 2)
        #expect(model.status.contains("more than one site matched") && publisher.calls.last?.isEmpty == true)
        try vault.ingest(source: source, origin: "POSTED", message: "@other.example #998877", timestamp: now.addingTimeInterval(2), now: now.addingTimeInterval(2))
        await model.synchronize()
        #expect(events.last?.eligible == 3 && events.last?.indexed == 1 && events.last?.withheld == 2)
    }

    @Test func vaultReadinessExposesCountsNotContents() throws {
        let storage = NativeCodeVaultTests.Storage()
        let vault = CodeVault(storage: storage)
        let disabled = try vault.readiness(now: Date())
        #expect(!disabled.enabled && disabled.sources == 0 && disabled.eligible == 0)
        try vault.enable()
        let source = try #require(NotificationCodeSource(installationID: UUID().uuidString, shortcutKey: String(repeating: "a", count: 64)))
        try vault.bind(source, to: UUID())
        let now = Date()
        try vault.ingest(source: source, origin: "POSTED", message: "@example.com #004321", timestamp: now, now: now)
        let ready = try vault.readiness(now: now)
        #expect(ready.enabled && ready.sources == 1 && ready.eligible == 1)
        #expect(try vault.readiness(now: now.addingTimeInterval(180)).eligible == 0)
    }
}
