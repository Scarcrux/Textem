import AppKit
import Foundation
import SwiftUI
import Testing
@testable import scarcrux_textem

private actor HistoryReplyGate {
    var continuation: CheckedContinuation<[PhoneHistorySnapshot], any Error>?
    func fetch() async throws -> [PhoneHistorySnapshot] { try await withCheckedThrowingContinuation { continuation = $0 } }
    func waiting() -> Bool { continuation != nil }
    func finish(_ value: [PhoneHistorySnapshot]) { continuation?.resume(returning: value); continuation = nil }
}

@Suite("Selected provider history", .serialized) @MainActor
struct PhoneHistoryTests {
    let install = "57b2dd91-cfa8-4193-9a38-e2d6d6470625"
    let context = PhoneImageConversation(accountID: UUID(uuidString: "36dc7528-a51a-4620-904b-a6ca2ab423f7")!, route: "fixture-history", label: "Example history")
    func object() -> [String: Any] {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var messages: [[String: Any]] = []
        for index in 0..<3 {
            let time: Int64 = now - Int64(3 - index) * 86_400_000
            let row: [String: Any] = ["id": String(repeating: String(index), count: 64),
                "timestamp_ms": time, "text": "Synthetic older message \(index)",
                "direction": index == 1 ? "SENT" : "RECEIVED", "truncated": false,
                "attachments_omitted": index == 2 ? 1 : 0, "parts_complete": true]
            messages.append(row)
        }
        return ["schema": 1, "kind": "SELECTED_PHONE_HISTORY", "install_id": install,
            "source_key": String(repeating: "a", count: 64), "captured_at_ms": now,
            "complete": false, "sms": "OK", "mms": "OK", "limited": false, "messages": messages]
    }
    func fixture(_ changes: [String: Any] = [:]) throws -> PhoneHistorySnapshot {
        var object = object(); object.merge(changes, uniquingKeysWith: { _, new in new })
        return try PhoneHistorySnapshot.parse(JSONSerialization.data(withJSONObject: object))
    }
    func root() throws -> URL { try PhoneImageTests().temporary() }
    @Test func oldMessageDatesRemainDistinctFromPublicationTime() throws {
        let sample = try fixture()
        #expect(sample.messages.count == 3 && sample.messages.first!.timestampMS < sample.capturedAtMS - 86_400_000)
        #expect(sample.messages[1].direction == "SENT" && sample.messages[2].attachmentsOmitted == 1)
        #expect(!sample.complete)
    }
    @Test func strictSchemaRejectsSyntheticCompleteUnknownAndBooleanNumbers() throws {
        for (key, value): (String, Any) in [("schema", true), ("kind", "SYNTHETIC_SELECTED_HISTORY"),
            ("complete", true), ("complete", 0), ("limited", 1), ("captured_at_ms", true),
            ("source_key", "raw-provider-id"), ("sms", "PRIVATE_SENTINEL"), ("extra", "PRIVATE_SENTINEL")] {
            #expect(throws: (any Error).self) { try fixture([key: value]) }
        }
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: object()), as: UTF8.self)
        #expect(throws: (any Error).self) { try PhoneHistorySnapshot.parse(Data(raw.replacingOccurrences(of: "\"schema\":1", with: "\"schema\":1,\"schema\":1").utf8)) }
        #expect(throws: (any Error).self) { try PhoneHistorySnapshot.parse(Data(repeating: 32, count: PhoneHistorySnapshot.maximumBytes + 1)) }
    }
    @Test func rejectsDuplicateRowsBadDirectionPartsAndUnorderedTimes() throws {
        let rows = try #require(object()["messages"] as? [[String: Any]])
        for changes: [String: Any] in [["id": rows[1]["id"]!], ["direction": "GUESSED"],
            ["timestamp_ms": true], ["timestamp_ms": Int64.max], ["parts_complete": 1],
            ["attachments_omitted": 33], ["text": String(repeating: "x", count: 20_001)]] {
            var changed = rows; changed[0].merge(changes, uniquingKeysWith: { _, new in new })
            #expect(throws: (any Error).self) { try fixture(["messages": changed]) }
        }
        #expect(throws: (any Error).self) { try fixture(["messages": Array(rows.reversed())]) }
    }
    @Test func libraryChecksPhoneIdentityAndNeverAcceptsNotificationKinds() throws {
        let sample = try fixture()
        let data = try JSONSerialization.data(withJSONObject: ["schema": 1, "kind": "PHONE_HISTORY_LIBRARY", "samples": [object()]])
        #expect(try PhoneHistorySnapshot.library(data, installID: install).count == 1)
        #expect(throws: (any Error).self) { try PhoneHistorySnapshot.library(data, installID: UUID().uuidString.lowercased()) }
        #expect(throws: (any Error).self) { try PhoneNotificationSnapshot.parse(JSONEncoder().encode(sample)) }
        let stale = Int64(Date().timeIntervalSince1970 * 1000) - 8 * 86_400_000
        var old = object(); old["captured_at_ms"] = stale; old["messages"] = []
        let oldData = try JSONSerialization.data(withJSONObject: old)
        #expect(throws: (any Error).self) { try PhoneHistorySnapshot.parse(oldData) }
        #expect(try PhoneHistorySnapshot.parse(oldData, requireFresh: false).messages.isEmpty)
    }
    @Test func accountRouteIsolationOfflineReopenAndRemoval() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let sample = try fixture(); try PhoneHistoryStore.link(sample, to: context, in: directory)
        #expect(try PhoneHistoryStore.record(for: context, in: directory)?.snapshot == sample)
        let other = PhoneImageConversation(accountID: UUID(), route: context.route, label: context.label)
        #expect(try PhoneHistoryStore.record(for: other, in: directory) == nil)
        #expect(throws: PhoneConversationError.alreadyLinked) { try PhoneHistoryStore.link(sample, to: other, in: directory) }
        let library = SavedPhoneConversationsModel(accountID: context.accountID,
            directory: directory.appendingPathComponent("notification-cache"), historyDirectory: directory)
        #expect(library.showHistory && library.selectedHistory?.snapshot == sample)
        #expect(SavedPhoneConversationsModel(accountID: UUID(), directory: directory.appendingPathComponent("other"), historyDirectory: directory).histories.isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("history.json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try PhoneHistoryStore.removeAccount(context.accountID, in: directory)
        #expect(try PhoneHistoryStore.load(in: directory).isEmpty)
    }
    @Test func refusesSymlinksAndPublicCacheFiles() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        try PhoneHistoryStore.link(fixture(), to: context, in: directory)
        let file = directory.appendingPathComponent("history.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(throws: (any Error).self) { try PhoneHistoryStore.load(in: directory) }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: directory.appendingPathComponent("absent"))
        #expect(throws: (any Error).self) { try PhoneHistoryStore.link(fixture(), to: context, in: directory) }
    }
    @Test func privateNamesKeepLegacyHistoryFormatAndAreRemovedWithHistory() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try PhoneHistoryStore.link(fixture(), to: context, in: directory))
        let record = try #require(try PhoneHistoryStore.record(for: context, in: directory))
        #expect(try PhoneHistoryStore.displayName(for: record, in: directory) == context.label)
        let file = directory.appendingPathComponent(record.conversationKey + ".name.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(!file.lastPathComponent.contains(context.label))
        let data = try Data(contentsOf: directory.appendingPathComponent("history.json"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["schema", "records"])
        let rows = try #require(object["records"] as? [[String: Any]])
        #expect(Set(rows[0].keys) == ["accountKey", "conversationKey", "sourceKey", "snapshot"])
        #expect(!String(decoding: data, as: UTF8.self).contains(context.route))
        #expect(!String(decoding: data, as: UTF8.self).contains(context.label))
        try PhoneHistoryStore.unlink(context, in: directory)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try PhoneHistoryStore.link(fixture(), to: context, in: directory)
        try PhoneHistoryStore.removeAccount(context.accountID, in: directory)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
    @Test func badNameMetadataCannotRenameAnotherAccountOrLoseSavedMessages() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        try PhoneHistoryStore.link(fixture(), to: context, in: directory)
        let record = try #require(try PhoneHistoryStore.record(for: context, in: directory))
        let file = directory.appendingPathComponent(record.conversationKey + ".name.json")
        var fields = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        fields["accountKey"] = String(repeating: "f", count: 64)
        try JSONSerialization.data(withJSONObject: fields).write(to: file)
        #expect(throws: PhoneHistoryError.invalid) { try PhoneHistoryStore.displayName(for: record, in: directory) }
        let model = SavedPhoneConversationsModel(accountID: context.accountID, directory: directory.appendingPathComponent("previews"), historyDirectory: directory)
        #expect(model.conversations.first?.name == "Name unavailable")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(try !PhoneHistoryStore.link(fixture(), to: context, in: directory))
        #expect(try PhoneHistoryStore.record(for: context, in: directory)?.snapshot.messages.count == 3)
        #expect(throws: (any Error).self) { try PhoneHistoryStore.displayName(for: record, in: directory) }
    }
    @Test func lateReplyAfterNavigationOrDisconnectCannotPersist() async throws {
        for disconnect in [false, true] {
            let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
            let gate = HistoryReplyGate(); let sample = try fixture()
            let model = PhoneConversationModel(context: context, directory: directory, fetchHistory: { try await gate.fetch() })
            model.validate = { _ in true }
            let task = Task { await model.readHistory() }
            while !(await gate.waiting()) { await Task.yield() }
            if disconnect { model.connectionChanged() } else { model.cancel() }
            await gate.finish([sample]); await task.value
            #expect(model.historyCandidates.isEmpty && model.history == nil && !model.busy)
            #expect(try PhoneHistoryStore.load(in: model.historyDirectory).isEmpty)
        }
    }
    @Test func explicitConfirmationRequiredAndRouteRechecked() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let sample = try fixture()
        let model = PhoneConversationModel(context: context, directory: directory, fetchHistory: { [sample] })
        model.validate = { _ in true }; await model.readHistory()
        #expect(model.historyCandidate == sample && model.history == nil)
        model.validate = { _ in false }; await model.linkHistory()
        #expect(try PhoneHistoryStore.load(in: model.historyDirectory).isEmpty)
        model.validate = { _ in true }; await model.linkHistory()
        #expect(model.history?.snapshot == sample && model.showHistory)
        model.unlinkHistory(); #expect(model.history == nil)
    }
    @Test func refusesDifferentPublishedThreadForKnownBinding() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let original = try fixture(); let other = try fixture(["source_key": String(repeating: "b", count: 64)])
        let historyDir = directory.appendingPathComponent("SelectedHistory")
        try PhoneHistoryStore.link(original, to: context, in: historyDir)
        let before = try Data(contentsOf: historyDir.appendingPathComponent("history.json"))
        let model = PhoneConversationModel(context: context, directory: directory, fetchHistory: { [other] })
        model.validate = { _ in true }; await model.readHistory()
        #expect(model.history?.snapshot == original && model.historyCandidates.isEmpty)
        #expect(try Data(contentsOf: historyDir.appendingPathComponent("history.json")) == before)
    }
    @Test func historyTransportHasNoDeveloperFallback() async throws {
        let sample = try fixture(); let pairing = try CompanionConnectionTests().pairing()
        let transport = CompanionHistoryTransport(load: { pairing }, network: { _ in [sample] })
        #expect(try await transport.fetch() == [sample])
        for data: Data? in [nil, Data(), Data("malformed".utf8)] {
            let absent = CompanionHistoryTransport(load: { data }, network: { _ in Issue.record("Unauthorized network attempt"); return [sample] })
            await #expect(throws: (any Error).self) { try await absent.fetch() }
        }
    }
    @Test func historyReplyRequiresRequestBindingAndPairedInstallation() throws {
        let pairing = try CompanionPairing.parse(CompanionConnectionTests().pairing())
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: ["schema": 1, "kind": "PHONE_HISTORY_LIBRARY", "samples": [object()]])
        func response(_ request: String) -> HTTPURLResponse {
            HTTPURLResponse(url: pairing.endpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json", "X-Textem-Request-ID": request])!
        }
        #expect(try CompanionHistoryTransport.validateReply(data, response: response(id.uuidString.lowercased()), requestID: id, pairing: pairing).count == 1)
        #expect(throws: CompanionConnectionError.invalidReply) {
            try CompanionHistoryTransport.validateReply(data, response: response(UUID().uuidString.lowercased()), requestID: id, pairing: pairing)
        }
        let other = try CompanionPairing.parse(CompanionConnectionTests().pairing(["install_id": UUID().uuidString.lowercased()]))
        #expect(throws: (any Error).self) {
            try CompanionHistoryTransport.validateReply(data, response: response(id.uuidString.lowercased()), requestID: id, pairing: other)
        }
    }
    @Test func historyDiagnosticReportsPositiveAndAbsentSourceSeparately() async throws {
        let pairing = try CompanionConnectionTests().pairing()
        let notification = try PhoneNotificationTests().fixture()
        let history = try fixture()
        let ready = await PhoneRecoveryCheck.collect(load: { pairing }, fetch: { _ in .init(samples: [notification], dropped: 0) },
            records: { [] }, history: { [history] })
        #expect(ready.state == .connected && ready.historyState == "ready" && ready.publishedHistoryRows == 3)
        let missing = await PhoneRecoveryCheck.collect(load: { pairing }, fetch: { _ in .init(samples: [notification], dropped: 0) },
            records: { [] }, history: { throw PhoneHistoryError.notPublished })
        #expect(missing.state == .connected && missing.historyState == "notPublished" && missing.publishedHistoryRows == 0)
    }
    @Test func publishingAndUnlinkingHistoryPreservesNotificationCacheBytes() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let preview = try PhoneNotificationTests().fixture(picture: true)
        try PhoneConversationStore.link(preview, to: context, in: directory)
        let file = directory.appendingPathComponent("previews.json"), before = try Data(contentsOf: file)
        let historyDir = directory.appendingPathComponent("SelectedHistory")
        try PhoneHistoryStore.link(fixture(), to: context, in: historyDir)
        try PhoneHistoryStore.unlink(context, in: historyDir)
        #expect(try Data(contentsOf: file) == before)
    }
    @Test func actualHistoryComponentsRenderInPaneAtNarrowAndWideSizes() throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let sample = try fixture()
        try PhoneHistoryStore.link(sample, to: context, in: directory.appendingPathComponent("SelectedHistory"))
        let model = PhoneConversationModel(context: context, directory: directory,
            fetch: { _ in throw PhoneHistoryError.invalid }, fetchHistory: { throw PhoneHistoryError.invalid })
        model.automatic = false
        for width: CGFloat in [430, 760] {
            for dark in [false, true] {
                let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
                let view = NSHostingView(rootView: PhoneConversationView(model: model, onClose: {}, onImages: {})
                    .frame(width: width, height: 720))
                view.frame = NSRect(x: 0, y: 0, width: width, height: 720)
                let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = appearance; window.contentView = view
                view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                var colors = Set<Int>()
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
                    for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                            colors.insert(Int(color.redComponent * 255) << 16 | Int(color.greenComponent * 255) << 8 | Int(color.blueComponent * 255))
                        }
                    }
                }
                // ImageRenderer can produce a blank lazy ScrollView; size alone cannot validate a render.
                #expect(colors.count > 20)
                if let folder = ProcessInfo.processInfo.environment["TEXTEM_HISTORY_SNAPSHOTS"] {
                    let url = URL(fileURLWithPath: folder).appendingPathComponent("history-\(Int(width))-\(dark ? "dark" : "light").png")
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
                }
                window.contentView = nil; view.removeFromSuperview()
            }
        }
    }
}
