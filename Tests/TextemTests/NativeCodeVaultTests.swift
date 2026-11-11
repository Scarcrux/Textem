import AppKit
import AuthenticationServices
import Foundation
import NativeAutoFillCore
import NativeAutoFillProvider
import SwiftUI
import Testing
@testable import scarcrux_textem

@Suite("Protected native code feed") @MainActor
struct NativeCodeVaultTests {
    @MainActor final class Storage: CodeStorage {
        var data: Data?; var writes = 0; var locked = false
        var onDeleted: (() -> Void)?
        func read() throws -> Data? { if locked { throw CodeVaultError.unavailable(-25308) }; return data }
        func write(_ data: Data) throws { if locked { throw CodeVaultError.unavailable(-25308) }; self.data = data; writes += 1 }
        func delete() throws {
            if locked { throw CodeVaultError.unavailable(-25308) }
            data = nil; let callback = onDeleted; onDeleted = nil; callback?()
        }
    }
    @MainActor final class Publisher: CodeIndexPublishing {
        var calls: [[CodeIndexEntry]] = []
        var block = false
        var failure: Error?
        var continuation: CheckedContinuation<Void, Never>?
        var onEntered: (() -> Void)?
        func replace(_ entries: [CodeIndexEntry]) async throws {
            if let failure { throw failure }
            if block { await withCheckedContinuation { continuation = $0; onEntered?() } }
            calls.append(entries)
        }
        func release() { block = false; continuation?.resume(); continuation = nil }
    }
    let time = Date(timeIntervalSince1970: 1_700_000_000)
    let account = UUID()
    let source = NotificationCodeSource(installationID: "00000000-0000-4000-8000-000000000001", shortcutKey: String(repeating: "a", count: 64))!
    let text = "Your verification code is 004321.\n@example.com #004321"
    func configure() throws -> (Storage, CodeVault) {
        let storage = Storage(); let vault = CodeVault(storage: storage)
        try vault.enable(); try vault.bind(source, to: account)
        return (storage, vault)
    }
    func snapshot(origin: String = "POSTED", timestamp: Date? = nil, kind: String = "NOTIFICATION_CONTENT") -> PhoneNotificationSnapshot {
        PhoneNotificationSnapshot(schema: 1, kind: kind, capturedAtMS: Int64(time.timeIntervalSince1970 * 1000), origin: origin,
            installID: source.installationID.uuidString.lowercased(), sourceKey: source.shortcutKey, title: "Synthetic code source",
            messages: [.init(timestampMS: Int64((timestamp ?? time).timeIntervalSince1970 * 1000), text: text, truncated: false)],
            truncated: false, image: nil, imageState: "ABSENT", uriAttachments: 0, complete: false)
    }

    @Test func protectedStateDefaultsOffAndDoesNotPersistMessageBody() throws {
        let storage = Storage(); let vault = CodeVault(storage: storage)
        #expect(try !vault.isEnabled())
        #expect(throws: CodeVaultError.disabled) { try vault.bind(source, to: account) }
        try vault.enable(); try vault.bind(source, to: account)
        #expect(try vault.ingest(source: source, origin: "POSTED", message: text, timestamp: time, now: time))
        let data = try #require(storage.data)
        let persisted = try #require(String(data: data, encoding: .utf8))
        #expect(!persisted.contains("Your verification code"))
        #expect(try vault.eligible(now: time).first?.code == "004321")
        #expect(KeychainCodeStorage.accessGroup.hasPrefix("K466Z7J2AS."))
    }

    @Test func repeatedImportCannotReageOrDuplicateReceipt() throws {
        let (_, vault) = try configure()
        #expect(try vault.ingest(source: source, origin: "POSTED", message: text, timestamp: time, now: time))
        let original = try #require(vault.eligible(now: time).first)
        #expect(try !vault.ingest(source: source, origin: "POSTED", message: text, timestamp: time, now: time.addingTimeInterval(179)))
        #expect(try vault.eligible(now: time.addingTimeInterval(179)) == [original])
        #expect(try !vault.ingest(source: source, origin: "POSTED", message: text, timestamp: time, now: time.addingTimeInterval(180)))
        #expect(try vault.eligible(now: time.addingTimeInterval(180)).isEmpty)
        try vault.prune(now: time.addingTimeInterval(180))
        #expect(try vault.eligible(now: time.addingTimeInterval(180)).isEmpty)
    }

    @Test func sourceOriginTimestampAndRevocationControls() throws {
        let (_, vault) = try configure()
        let wrong = NotificationCodeSource(installationID: UUID().uuidString, shortcutKey: source.shortcutKey)!
        #expect(throws: CodeVaultError.unboundSource) {
            try vault.ingest(source: wrong, origin: "POSTED", message: text, timestamp: time, now: time)
        }
        for origin in ["SYNTHETIC", "ACTIVE_SCAN", ""] {
            #expect(try !vault.ingest(source: source, origin: origin, message: text, timestamp: time, now: time))
        }
        for timestamp in [time.addingTimeInterval(1), time.addingTimeInterval(-180), Date(timeIntervalSince1970: 0)] {
            #expect(try !vault.ingest(source: source, origin: "POSTED", message: text, timestamp: timestamp, now: time))
        }
        try vault.ingest(source: source, origin: "POSTED", message: text, timestamp: time, now: time)
        try vault.unbind(source); #expect(try vault.eligible(now: time).isEmpty)
        try vault.bind(source, to: account)
        try vault.ingest(source: source, origin: "POSTED", message: text, timestamp: time, now: time)
        try vault.removeAccount(account); #expect(try vault.eligible(now: time).isEmpty)
    }

    @Test func clearLockedAndMalformedStorageFailClosed() throws {
        let (storage, vault) = try configure()
        try vault.ingest(source: source, origin: "POSTED", message: text, timestamp: time, now: time)
        storage.locked = true
        #expect(throws: CodeVaultError.unavailable(-25308)) { try vault.eligible(now: time) }
        #expect(throws: CodeVaultError.unavailable(-25308)) { try vault.disableAndClear() }
        storage.locked = false
        try vault.disableAndClear(); #expect(storage.data == nil)
        try vault.prune(now: time); #expect(storage.data == nil)
        #expect(try vault.eligible(now: time).isEmpty)
        storage.data = Data("corrupt".utf8)
        #expect(throws: CodeVaultError.malformed) { try vault.eligible(now: time) }
        storage.data = Data(repeating: 0, count: CodeVault.maximumBytes + 1)
        #expect(throws: CodeVaultError.malformed) { try vault.enable() }
    }

    @Test func indexContainsNoCodeAndSuppressesAmbiguousDomains() throws {
        let sample = try #require(CodeSample(message: text, accountID: account, receivedAt: time, consent: true))
        let entries = CodeIndexEntry.project([sample], now: time)
        #expect(entries.count == 1 && entries[0].domain == "example.com")
        #expect(!entries[0].label.contains(sample.code) && entries[0].recordID == sample.id.uuidString)
        #expect(CodeIndexEntry.project([sample, sample], now: time).isEmpty)
        #expect(CodeIndexEntry.project([sample], now: time.addingTimeInterval(180)).isEmpty)
    }

    @Test func realNotificationAdapterRequiresBindingAndOriginalTimestamp() async throws {
        let storage = Storage(); let vault = CodeVault(storage: storage); let publisher = Publisher()
        let model = NativeAutoFillCoordinator(vault: vault, publisher: publisher, available: true, clock: { time }, accountExists: { $0 == account })
        await model.setEnabled(true)
        await model.ingest(snapshot()); #expect(try vault.eligible(now: time).isEmpty)
        await model.bind(snapshot(), accountID: UUID())
        #expect(try vault.eligible(now: time).isEmpty)
        await model.bind(snapshot(), accountID: account)
        #expect(try vault.eligible(now: time).count == 1)
        #expect(publisher.calls.last?.count == 1)
        await model.setEnabled(false)
        #expect(storage.data == nil && publisher.calls.last == [])
        await model.setEnabled(true)
        await model.bind(snapshot(timestamp: time.addingTimeInterval(-180)), accountID: account)
        #expect(try vault.eligible(now: time).isEmpty)
        await model.ingest(snapshot(kind: "SYNTHETIC_NOTIFICATION_CONTENT"))
        #expect(try vault.eligible(now: time).isEmpty)
        await model.setEnabled(false)
    }

    @Test func queuedPublicationCannotFinishAfterDisableClear() async throws {
        let (storage, vault) = try configure(); let publisher = Publisher()
        let model = NativeAutoFillCoordinator(vault: vault, publisher: publisher, available: true, clock: { time }, accountExists: { _ in true })
        try vault.ingest(source: source, origin: "POSTED", message: text, timestamp: time, now: time)
        publisher.block = true
        await withCheckedContinuation { entered in
            publisher.onEntered = { entered.resume() }
            Task { await model.synchronize() }
        }
        var clear: Task<Void, Never>?
        await withCheckedContinuation { deleted in
            storage.onDeleted = { deleted.resume() }
            clear = Task { await model.setEnabled(false) }
        }
        // The real injected storage delete has completed while publication is
        // still blocked, proving delivery of the race condition being tested.
        publisher.release(); await clear?.value
        #expect(publisher.calls.last == [])
        #expect(try vault.eligible(now: time).isEmpty)
    }

    @Test func unavailableBuildNeverTouchesInjectedStorageOrPublisher() async throws {
        let storage = Storage(); storage.locked = true; let publisher = Publisher()
        let model = NativeAutoFillCoordinator(vault: CodeVault(storage: storage), publisher: publisher, available: false, accountExists: { _ in true })
        await model.setEnabled(true); await model.ingest(snapshot()); await model.synchronize()
        #expect(!model.enabled && storage.writes == 0 && publisher.calls.isEmpty)
    }

    @Test func nativeDialogRereadsProtectedVaultAfterClear() throws {
        guard #available(macOS 15, *) else { return }
        let (_, vault) = try configure()
        try vault.ingest(source: source, origin: "POSTED", message: text, timestamp: time, now: time)
        let provider = CredentialProvider()
        provider.readSamples = { (try? vault.eligible(now: time)) ?? [] }
        provider.now = { time }
        var result: String?
        provider.testCompletion = { result = $0 }
        provider.prepareOneTimeCodeCredentialList(for: [ASCredentialServiceIdentifier(identifier: "example.com", type: .domain)])
        try vault.disableAndClear()
        provider.fillCode(); #expect(result == nil)
    }

    @Test func settingsExplainUnavailableNativeBuild() throws {
        let storage = Storage(); storage.locked = true
        let model = NativeAutoFillCoordinator(vault: CodeVault(storage: storage), publisher: Publisher(), available: false, accountExists: { _ in false })
        let view = NSHostingView(rootView: SettingsView(nativeCodes: model))
        view.appearance = NSAppearance(named: .aqua)
        view.frame = NSRect(x: 0, y: 0, width: 460, height: 740)
        view.layoutSubtreeIfNeeded()
        if let path = ProcessInfo.processInfo.environment["TEXTEM_AUTOFILL_SETTINGS_FIXTURE"] {
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path))
        }
        #expect(model.status.contains("provisioned") && !model.enabled && storage.writes == 0)
    }

    @Test func disabledSystemProviderNeverClaimsNativeSuggestionSuccess() async throws {
        let storage = Storage(); let publisher = Publisher(); publisher.failure = NativeCodeSetupError.notEnabled
        let model = NativeAutoFillCoordinator(vault: CodeVault(storage: storage), publisher: publisher, available: true, accountExists: { _ in true })
        await model.setEnabled(true)
        #expect(model.status.contains("not active") && !model.status.contains("provider updated"))
        await model.setEnabled(false)
        #expect(!model.enabled && storage.data == nil && model.status.contains("off"))
    }

    @Test func explicitClearCanRecoverCorruptVaultWithoutDecodingIt() async throws {
        let storage = Storage(); storage.data = Data("corrupt".utf8)
        let model = NativeAutoFillCoordinator(vault: CodeVault(storage: storage), publisher: Publisher(), available: true, accountExists: { _ in true })
        #expect(!model.enabled)
        await model.setEnabled(false)
        #expect(storage.data == nil && model.status.contains("off"))
    }

    @Test func macSampleClearReportsRevocationFailureAndPreservesSample() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("textem-revocation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sample = try PhoneNotificationTests().fixture()
        try PhoneNotificationStore.save(sample, in: root)
        let beforeEndpoint = UserDefaults.standard.string(forKey: "phoneImageEndpoint")
        let failed = PhoneNotificationModel(directory: root, revokeCodes: { _ in throw CodeVaultError.unavailable(-25308) })
        failed.clear()
        #expect(failed.status.contains("revocation") && !failed.status.contains("storage is not private"))
        let retained = try PhoneNotificationStore.load(in: root)
        #expect(failed.snapshot == sample && retained == sample)
        var revoked = false
        let success = PhoneNotificationModel(directory: root, revokeCodes: { _ in revoked = true })
        success.clear()
        #expect(revoked && success.snapshot == nil)
        #expect(try PhoneNotificationStore.load(in: root) == nil)
        #expect(UserDefaults.standard.string(forKey: "phoneImageEndpoint") == beforeEndpoint)
    }
}
