import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import scarcrux_textem

private actor PreviewGate {
    var continuation: CheckedContinuation<PhoneNotificationSnapshot, any Error>?
    func fetch() async throws -> PhoneNotificationSnapshot {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func waiting() -> Bool { continuation != nil }
    func finish(_ value: PhoneNotificationSnapshot) { continuation?.resume(returning: value); continuation = nil }
}

@Suite("Explicit phone conversation recovery", .serialized) @MainActor
struct PhoneConversationTests {
    let context = PhoneImageConversation(accountID: UUID(uuidString: "36dc7528-a51a-4620-904b-a6ca2ab423f7")!, route: "fixture-route", label: "Example delivery")
    func fixture(picture: Bool = false, changes: [String: Any] = [:]) throws -> PhoneNotificationSnapshot {
        let value = try PhoneNotificationTests().fixture(picture: picture)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        for (key, value) in changes { object[key] = value }
        return try PhoneNotificationSnapshot.parse(JSONSerialization.data(withJSONObject: object))
    }
    func temp() throws -> URL { try PhoneImageTests().temporary() }
    @Test func linkPersistsTextAndPictureAndNeverGuessesFromLabel() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let sample = try fixture(picture: true)
        #expect(try PhoneConversationStore.record(for: context, in: root) == nil)
        try PhoneConversationStore.link(sample, to: context, in: root)
        let reopened = try #require(try PhoneConversationStore.record(for: context, in: root))
        #expect(reopened.samples == [sample] && reopened.samples.first?.image?.data == sample.image?.data)
        for other in [PhoneImageConversation(accountID: UUID(), route: context.route, label: context.label),
                      PhoneImageConversation(accountID: context.accountID, route: "other-route", label: context.label)] {
            #expect(try PhoneConversationStore.record(for: other, in: root) == nil)
            #expect(throws: PhoneConversationError.alreadyLinked) { try PhoneConversationStore.link(sample, to: other, in: root) }
        }
        let otherSource = try fixture(changes: ["source_key": String(repeating: "b", count: 64)])
        #expect(throws: PhoneConversationError.alreadyLinked) { try PhoneConversationStore.link(otherSource, to: context, in: root) }
        #expect(throws: PhoneConversationError.invalid) { try PhoneConversationStore.ingest(otherSource, for: context, in: root) }
        #expect(try PhoneConversationStore.record(for: context, in: root) == reopened)
        let raw = try String(contentsOf: root.appendingPathComponent("previews.json"), encoding: .utf8)
        #expect(!raw.contains(context.route) && !raw.contains(context.accountID.uuidString) && !raw.contains(context.label))
        var info = stat(); #expect(lstat(root.appendingPathComponent("previews.json").path, &info) == 0)
        #expect(info.st_mode & 0o077 == 0)
    }
    @Test func dedupDoesNotReageAndRetentionIsBounded() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let base = Int64(Date().timeIntervalSince1970 * 1000) - 10000
        let first = try fixture(changes: ["captured_at_ms": base])
        try PhoneConversationStore.link(first, to: context, in: root)
        try PhoneConversationStore.ingest(first, for: context, in: root)
        let rescan = try fixture(changes: ["captured_at_ms": base + 1000])
        try PhoneConversationStore.ingest(rescan, for: context, in: root)
        #expect(try PhoneConversationStore.record(for: context, in: root)?.samples == [first])
        for index in 1...6 {
            let changed = try fixture(changes: ["captured_at_ms": base + Int64(index),
                "messages": [["timestamp_ms": 0, "text": "Changed preview \(index)", "truncated": false]]])
            try PhoneConversationStore.ingest(changed, for: context, in: root)
        }
        let record = try #require(try PhoneConversationStore.record(for: context, in: root))
        #expect(record.samples.count == 4 && record.samples.last?.messages.first?.text == "Changed preview 6")
        #expect(record.samples.first?.capturedAtMS == base + 3)
    }
    @Test func unlinkAndAccountRemovalAreScoped() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let other = PhoneImageConversation(accountID: UUID(), route: "other", label: context.label)
        try PhoneConversationStore.link(fixture(), to: context, in: root)
        try PhoneConversationStore.link(fixture(changes: ["source_key": String(repeating: "b", count: 64)]), to: other, in: root)
        try PhoneConversationStore.removeAccount(context.accountID, in: root)
        #expect(try PhoneConversationStore.record(for: context, in: root) == nil)
        #expect(try PhoneConversationStore.record(for: other, in: root) != nil)
        try PhoneConversationStore.unlink(other, in: root)
        #expect(try PhoneConversationStore.load(in: root).isEmpty)
    }
    @Test func malformedUnsafeAndSyntheticStorageFailsClosed() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        try PhoneConversationStore.link(fixture(), to: context, in: root)
        let file = root.appendingPathComponent("previews.json"); let original = try Data(contentsOf: file)
        for changed in [Data("{\"schema\":1,\"schema\":1,\"records\":[]}".utf8),
                        Data(repeating: 32, count: PhoneConversationStore.maximumBytes + 1),
                        Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "NOTIFICATION_CONTENT", with: "SYNTHETIC_NOTIFICATION_CONTENT").utf8)] {
            try changed.write(to: file); #expect(throws: (any Error).self) { try PhoneConversationStore.load(in: root) }
        }
        try original.write(to: file); chmod(file.path, 0o644)
        #expect(throws: (any Error).self) { try PhoneConversationStore.load(in: root) }
        chmod(file.path, 0o600)
        let target = root.appendingPathComponent("target.json"); try original.write(to: target); chmod(target.path, 0o600)
        try FileManager.default.removeItem(at: file); try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        #expect(throws: (any Error).self) { try PhoneConversationStore.load(in: root) }
        #expect(throws: (any Error).self) { try PhoneConversationStore.link(fixture(), to: context, in: root) }
        #expect(try Data(contentsOf: target) == original)
    }
    @Test func modelRequiresExplicitValidatedConfirmationAndOfflinePreservesCache() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let sample = try fixture(picture: true)
        let model = PhoneConversationModel(context: context, directory: root, endpoint: { "" }, fetch: { _ in .init(samples: [sample], dropped: 0) })
        model.validate = { _ in true }
        await model.read()
        #expect(model.candidate == sample && model.record == nil)
        #expect(try PhoneConversationStore.load(in: root).isEmpty)
        model.validate = { _ in false }; await model.link()
        #expect(try PhoneConversationStore.load(in: root).isEmpty)
        model.validate = { _ in true }; await model.link()
        #expect(model.record?.samples == [sample] && model.candidate == nil)
        let offline = PhoneConversationModel(context: context, directory: root, endpoint: { "" }, fetch: { _ in throw PhoneImageError.noDevice })
        offline.validate = { _ in true }; await offline.read()
        #expect(offline.record?.samples == [sample] && offline.status.contains("retained"))
        let wrong = try fixture(changes: ["source_key": String(repeating: "b", count: 64)])
        let mismatch = PhoneConversationModel(context: context, directory: root, endpoint: { "" }, fetch: { _ in .init(samples: [wrong], dropped: 0) })
        mismatch.validate = { _ in true }; await mismatch.read()
        #expect(mismatch.record?.samples == [sample] && mismatch.status.contains("another source"))
        model.unlink(); #expect(model.record == nil)
        await model.read(); #expect(model.candidate == sample)
    }
    @Test func cancelledFetchAndChangedRouteCannotPublish() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = PreviewGate(); let sample = try fixture()
        let model = PhoneConversationModel(context: context, directory: root, endpoint: { "" }, fetch: { _ in .init(samples: [try await gate.fetch()], dropped: 0) })
        model.validate = { _ in true }
        let task = Task { await model.read() }
        for _ in 0..<10000 { if await gate.waiting() { break }; await Task.yield() }
        #expect(await gate.waiting()); model.cancel(); await gate.finish(sample); await task.value
        #expect(!model.busy && model.candidate == nil && model.record == nil)
        #expect(try PhoneConversationStore.load(in: root).isEmpty)
        let changed = PhoneConversationModel(context: context, directory: root, endpoint: { "" }, fetch: { _ in .init(samples: [sample], dropped: 0) })
        changed.validate = { _ in false }; await changed.read()
        #expect(changed.candidate == nil && changed.record == nil)
    }
    @Test func nativePanePicturePositiveAndUnlinkedNegative() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let model = PhoneConversationModel(context: context, directory: root, endpoint: { "" }, fetch: { _ in throw PhoneImageError.noDevice })
        func orangeSamples() throws -> Int {
            let view = NSHostingView(rootView: PhoneConversationView(model: model, onClose: {}, onImages: {}))
            view.frame = NSRect(x: 0, y: 0, width: 760, height: 1200); view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
            let image = try #require(bitmap.cgImage); let width = image.width, height = image.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            return try pixels.withUnsafeMutableBytes { data in
                let ctx = try #require(CGContext(data: data.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                let bytes = data.bindMemory(to: UInt8.self)
                return stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] > 200 && bytes[$0+1] > 60 && bytes[$0+1] < 190 && bytes[$0+2] < 90 }.count
            }
        }
        #expect(try orangeSamples() == 0)
        try PhoneConversationStore.link(fixture(picture: true), to: context, in: root); model.reload()
        #expect(try orangeSamples() > 100)
        model.unlink(); #expect(try orangeSamples() == 0)
    }
    @Test func onlyHTTPSLinksBecomeActionsAndMarkupStaysLiteral() {
        let value = PhoneConversationSampleView.linkedText("<b>literal</b> https://example.com/offer http://example.com ftp://example.com")
        let links = value.runs.compactMap(\.link)
        #expect(links.count == 1 && links.first?.scheme == "https")
        #expect(String(value.characters).contains("<b>literal</b>"))
    }
    func journal(_ samples: [PhoneNotificationSnapshot], changes: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = ["schema": 1, "kind": "NOTIFICATION_JOURNAL", "epoch": "57b2dd91-cfa8-4193-9a38-e2d6d6470625",
            "revision": 1, "dropped": 0, "complete": false, "written_at_ms": Int64(Date().timeIntervalSince1970 * 1000),
            "samples": try samples.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }]
        for (key, value) in changes { object[key] = value }; return try JSONSerialization.data(withJSONObject: object)
    }
    @Test func journalFormatDiscriminatesRealAndUnsafeDocuments() throws {
        let sample = try fixture()
        let other = try fixture(changes: ["source_key": String(repeating: "b", count: 64)])
        let valid = try journal([sample, other])
        #expect(try PhoneNotificationJournal.parse(valid).samples == [sample, other])
        for (key, value): (String, Any) in [("schema", true), ("revision", 0), ("revision", true), ("dropped", -1),
            ("complete", true), ("complete", 0), ("kind", "SYNTHETIC_NOTIFICATION_JOURNAL"), ("epoch", "bad"),
            ("written_at_ms", 0), ("samples", []), ("extra", "refuse")] {
            #expect(throws: (any Error).self) { try PhoneNotificationJournal.parse(journal([sample], changes: [key: value])) }
        }
        let differentPhone = try fixture(changes: ["install_id": UUID().uuidString.lowercased()])
        #expect(throws: (any Error).self) { try PhoneNotificationJournal.parse(journal([sample, differentPhone])) }
        #expect(throws: (any Error).self) { try PhoneNotificationJournal.parse(journal(Array(repeating: sample, count: 5))) }
        let duplicateKey = Data(("{\"schema\":1," + String(decoding: valid, as: UTF8.self).dropFirst()).utf8)
        #expect(throws: (any Error).self) { try PhoneNotificationJournal.parse(duplicateKey) }
        let state = try PhoneNotificationTests().state(other, offset: 1)
        var reads = 0
        #expect(try PhoneImageADBClient.readNotificationJournal { name, _ in
            reads += 1; return name == "notification-journal.json" ? valid : state
        }.samples == [sample, other])
        #expect(reads == 3)
        reads = 0
        #expect(throws: PhoneNotificationError.changed) {
            try PhoneImageADBClient.readNotificationJournal { name, _ in
                reads += 1
                return reads == 3 ? try PhoneNotificationTests().state(sample, value: "CLEARED") : name == "notification-journal.json" ? valid : state
            }
        }
    }
    @Test func retainedJournalSurvivesLatestSourceFailureWithoutReaging() throws {
        let fresh = try fixture()
        let captured = fresh.capturedAtMS - 2 * 3_600_000
        let retained = try PhoneNotificationSnapshot.parse(
            PhoneNotificationTests().json(fresh, changing: "captured_at_ms", to: captured), requireFresh: false)
        let bytes = try journal([retained], changes: ["written_at_ms": captured + 1])
        for latestState in ["SAVED", "SOURCE_REQUIRED"] {
            let status = try PhoneNotificationTests().state(fresh, value: latestState)
            var reads: [String] = []
            let result = try PhoneImageADBClient.readNotificationJournal { name, _ in
                reads.append(name)
                return name == "notification-journal.json" ? bytes : status
            }
            #expect(result.samples == [retained])
            #expect(result.samples.first?.capturedAtMS == captured)
            #expect(reads == ["notification-content-state.json", "notification-journal.json", "notification-content-state.json"])
        }
    }
    @Test func journalReadStillHonorsPermissionDeletionAndTransactionGuards() throws {
        let sample = try fixture()
        let bytes = try journal([sample])
        for denied in ["OFF", "ACCESS_REQUIRED", "CLEARED", "REDACTED", "UNAVAILABLE", "NO_CONTENT"] {
            var reads = 0
            #expect(throws: (any Error).self) {
                try PhoneImageADBClient.readNotificationJournal { _, _ in
                    reads += 1
                    return try PhoneNotificationTests().state(sample, value: denied)
                }
            }
            #expect(reads == 1)
        }
        let status = try PhoneNotificationTests().state(sample, value: "SOURCE_REQUIRED", offset: 1)
        var reads = 0
        #expect(throws: PhoneNotificationError.changed) {
            try PhoneImageADBClient.readNotificationJournal { name, _ in
                reads += 1
                if reads == 3 { return try PhoneNotificationTests().state(sample, value: "CLEARED") }
                return name == "notification-journal.json" ? bytes : status
            }
        }
        #expect(reads == 3)
        #expect(throws: PhoneNotificationError.invalid) {
            try PhoneImageADBClient.readNotificationJournal { name, _ in
                name == "notification-journal.json" ? Data("{}".utf8) : status
            }
        }
        // The latest-only AutoFill path must still refuse SOURCE_REQUIRED.
        var latestReads = 0
        #expect(throws: PhoneNotificationError.sourceRequired) {
            try PhoneImageADBClient.readNotification { _, _ in latestReads += 1; return status }
        }
        #expect(latestReads == 1)
        var staleReads = 0
        #expect(throws: PhoneNotificationError.invalid) {
            try PhoneImageADBClient.readNotificationJournal { _, _ in
                staleReads += 1
                return try PhoneNotificationTests().state(sample, value: "SOURCE_REQUIRED", offset: -3_600_000)
            }
        }
        #expect(staleReads == 1)
    }
    @Test func retainedJournalAgeIsMeasuredAgainstNowNotOnlyItsWriteTime() throws {
        let fresh = try fixture(), now = Date()
        let sixDays = fresh.capturedAtMS - 6 * 86_400_000
        let retained = try PhoneNotificationSnapshot.parse(
            PhoneNotificationTests().json(fresh, changing: "captured_at_ms", to: sixDays), requireFresh: false)
        let bytes = try journal([retained], changes: ["written_at_ms": sixDays + 1])
        #expect(try PhoneNotificationJournal.parse(bytes, now: now).samples == [retained])
        #expect(throws: PhoneNotificationError.invalid) {
            try PhoneNotificationJournal.parse(bytes, now: now.addingTimeInterval(2 * 86_400))
        }
        // A newer write cannot resurrect a sample that has aged past retention.
        let expired = try PhoneNotificationSnapshot.parse(
            PhoneNotificationTests().json(fresh, changing: "captured_at_ms", to: fresh.capturedAtMS - 8 * 86_400_000), requireFresh: false)
        #expect(throws: PhoneNotificationError.invalid) {
            try PhoneNotificationJournal.parse(journal([expired]))
        }
        #expect(throws: PhoneNotificationError.invalid) {
            try PhoneNotificationJournal.parse(journal([fresh], changes: ["written_at_ms": fresh.capturedAtMS + 3_600_000]))
        }
    }
    @Test func journalSourcesRequireChoiceAndRefreshOnlyTheExplicitBinding() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try fixture(), b = try fixture(changes: ["source_key": String(repeating: "b", count: 64)])
        let model = PhoneConversationModel(context: context, directory: root, endpoint: { "" }, fetch: { _ in .init(samples: [a,b], dropped: 2) })
        model.validate = { _ in true }; await model.read()
        #expect(model.candidates.count == 2 && model.record == nil)
        model.chooseSource(PhoneConversationStore.sourceKey(b)); await model.link()
        #expect(model.record?.sourceKey == PhoneConversationStore.sourceKey(b))
        await model.read()
        #expect(model.record?.samples == [b] && model.status.contains("discarded 2"))
        #expect(try PhoneConversationStore.load(in: root).count == 1)
    }
    @Test func routeChangeAfterTransferStartedRefusesLateContent() async throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let sample = try fixture(); let gate = PreviewGate(); var routeValid = true
        let model = PhoneConversationModel(context: context, directory: root, endpoint: { "" }, fetch: { _ in .init(samples: [try await gate.fetch()], dropped: 0) })
        model.validate = { _ in routeValid }
        let task = Task { await model.read() }
        for _ in 0..<10000 { if await gate.waiting() { break }; await Task.yield() }
        #expect(await gate.waiting()); routeValid = false; await gate.finish(sample); await task.value
        #expect(model.candidate == nil && model.record == nil && !model.busy)
        #expect(try PhoneConversationStore.load(in: root).isEmpty)
    }
    @Test func sourceBindingCapDoesNotEvictExistingConversations() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<20 {
            let sample = try fixture(changes: ["source_key": String(format: "%064x", index)])
            let route = PhoneImageConversation(accountID: context.accountID, route: "fixture-\(index)", label: "Same fixture title")
            try PhoneConversationStore.link(sample, to: route, in: root)
        }
        let before = try PhoneConversationStore.load(in: root)
        #expect(throws: PhoneConversationError.full) { try PhoneConversationStore.link(fixture(), to: context, in: root) }
        #expect(try PhoneConversationStore.load(in: root) == before)
    }
}
