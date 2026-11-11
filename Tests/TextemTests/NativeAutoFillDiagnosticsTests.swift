import Foundation
import Testing
import NativeAutoFillCore
@testable import scarcrux_textem

@Suite("Private native AutoFill readiness") @MainActor
struct NativeAutoFillDiagnosticsTests {
    @Test func boundedPrivateMetadataSchemaAndSymlinkRefusal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("textem-readiness-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("readiness.jsonl")
        try NativeAutoFillDiagnostics.append(.ready, .init(capture: 7, provider: 1, sources: 90, eligible: -5), to: log)
        let data = try Data(contentsOf: log)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["at", "event", "capture", "provider", "sources", "eligible", "failure", "process"])
        #expect(object["event"] as? String == "ready" && object["sources"] as? Int == 16 && object["eligible"] as? Int == 0)
        #expect(object["capture"] as? Int == 1 && object["provider"] as? Int == 1)
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
