import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import scarcrux_textem

@Suite("Private notification preview") @MainActor
struct PhoneNotificationTests {
    func fixture(picture: Bool = false) throws -> PhoneNotificationSnapshot {
        var image: PhoneNotificationSnapshot.Picture?
        if picture {
            let (manifest, png) = try PhoneImageTests().fixture()
            image = .init(mime: "image/png", width: manifest.width, height: manifest.height, bytes: png.count,
                sha256: manifest.sha256, dataBase64: png.base64EncodedString())
        }
        return .init(schema: 1, kind: "NOTIFICATION_CONTENT", capturedAtMS: Int64(Date().timeIntervalSince1970 * 1000),
            origin: "ACTIVE_SCAN", installID: "57b2dd91-cfa8-4193-9a38-e2d6d6470625", sourceKey: String(repeating: "a", count: 64),
            title: "Synthetic notification source", messages: [.init(timestampMS: 0, text: "Fixture text <b>stays plain</b>", truncated: false)],
            truncated: false, image: image, imageState: picture ? "BITMAP_PREVIEW" : "ABSENT", uriAttachments: 0, complete: false)
    }
    func temporary() throws -> URL { try PhoneImageTests().temporary() }
    func json(_ snapshot: PhoneNotificationSnapshot, changing key: String, to value: Any) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        object[key] = value; return try JSONSerialization.data(withJSONObject: object)
    }
    func state(_ snapshot: PhoneNotificationSnapshot, value: String = "SAVED", offset: Int64 = 0) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schema": 1, "state": value, "recorded_at_ms": snapshot.capturedAtMS + offset])
    }
    @Test func realTextPictureRoundtripAndSyntheticRefusal() throws {
        for picture in [false, true] {
            let value = try fixture(picture: picture)
            #expect(try PhoneNotificationSnapshot.parse(JSONEncoder().encode(value)) == value)
            #expect(throws: PhoneNotificationError.invalid) {
                try PhoneNotificationSnapshot.parse(json(value, changing: "kind", to: "SYNTHETIC_NOTIFICATION_CONTENT"))
            }
        }
    }
    @Test func unknownBoundsTypesAndPreviewClaimsFailClosed() throws {
        let value = try fixture()
        for (key, input): (String, Any) in [("schema", true), ("complete", true), ("complete", 0), ("captured_at_ms", 0),
            ("captured_at_ms", value.capturedAtMS + 3_600_000), ("origin", "STATE"), ("truncated", 1),
            ("source_key", "PRIVATE_ID"), ("install_id", "not-an-id"), ("title", String(repeating: "x", count: 257)),
            ("messages", []), ("uri_attachments", 12), ("unknown", "PRIVATE_SENTINEL"), ("image_state", "BITMAP_PREVIEW")] {
            #expect(throws: PhoneNotificationError.invalid) { try PhoneNotificationSnapshot.parse(json(value, changing: key, to: input)) }
        }
        let data = try JSONEncoder().encode(value)
        #expect(throws: PhoneNotificationError.invalid) { try PhoneNotificationSnapshot.parse(Data(repeating: 0, count: PhoneNotificationSnapshot.maximumBytes + 1)) }
        #expect(throws: PhoneNotificationError.invalid) { try PhoneNotificationSnapshot.parse(Data("[]".utf8)) }
        #expect(try PhoneNotificationSnapshot.parse(data).complete == false)
    }
    @Test func duplicateKeysIncludingEscapedAndNestedAreRejected() throws {
        let valid = try JSONEncoder().encode(fixture())
        let object = try #require(String(data: valid, encoding: .utf8))
        for duplicate in ["\"schema\":1,", "\"sch\\u0065ma\":1,"] {
            let raw = "{" + duplicate + object.dropFirst()
            #expect(throws: PhoneNotificationError.invalid) { try PhoneNotificationSnapshot.parse(Data(raw.utf8)) }
        }
        for number in ["1.0", "1e0"] {
            let raw = object.replacingOccurrences(of: "\"schema\":1", with: "\"schema\":" + number)
            #expect(throws: PhoneNotificationError.invalid) { try PhoneNotificationSnapshot.parse(Data(raw.utf8)) }
        }
        #expect(throws: PhoneNotificationError.invalid) {
            try PhoneNotificationJSON.object(Data("{\"nested\":{\"x\":1,\"x\":2}}".utf8), maximum: 4096)
        }
        #expect(try PhoneNotificationJSON.object(Data("{\"x\":\"a,\\\"x\\\":b\",\"nested\":{\"x\":2}}".utf8), maximum: 4096).count == 2)
    }
    @Test func pngIntegrityAndNestedSchemaAreEnforced() throws {
        let value = try fixture(picture: true)
        let data = try JSONEncoder().encode(value)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let good = try #require(object["image"] as? [String: Any])
        for (key, input): (String, Any) in [("width", 2049), ("width", true), ("height", 0), ("bytes", 1_048_577),
            ("sha256", String(repeating: "0", count: 64)), ("data_base64", "not valid"), ("filename", "../private")] {
            var bad = good; bad[key] = input; object["image"] = bad
            #expect(throws: PhoneNotificationError.invalid) {
                try PhoneNotificationSnapshot.parse(JSONSerialization.data(withJSONObject: object))
            }
        }
        object["image"] = good
        object["messages"] = [["timestamp_ms": 0, "text": "fixture", "truncated": false, "sender": "PRIVATE"]]
        #expect(throws: PhoneNotificationError.invalid) { try PhoneNotificationSnapshot.parse(JSONSerialization.data(withJSONObject: object)) }
    }
    @Test func fixedStateSampleStateTransportRefusesRacesAndUnsupported() throws {
        let value = try fixture(); let saved = try state(value); let content = try JSONEncoder().encode(value)
        var reads: [String] = []
        let result = try PhoneImageADBClient.readNotification { name, maximum in
            reads.append(name)
            #expect(maximum == (name == "notification-content.json" ? PhoneNotificationSnapshot.maximumBytes : 4096))
            return name == "notification-content.json" ? content : saved
        }
        #expect(result == value && reads == ["notification-content-state.json", "notification-content.json", "notification-content-state.json"])
        var count = 0
        #expect(throws: PhoneNotificationError.changed) {
            try PhoneImageADBClient.readNotification { name, _ in
                count += 1; return count == 3 ? try state(value, value: "CLEARED") : name == "notification-content.json" ? content : saved
            }
        }
        count = 0
        #expect(throws: PhoneNotificationError.unsupported) {
            try PhoneImageADBClient.readNotification { _, _ in count += 1; return try state(value, value: "URI_ONLY_UNSUPPORTED") }
        }
        #expect(count == 1)
        for (stateValue, expected): (String, PhoneNotificationError) in [("OFF", .contentOff), ("ACCESS_REQUIRED", .accessRequired),
                ("SOURCE_REQUIRED", .sourceRequired), ("REDACTED", .redacted), ("MALFORMED", .malformed), ("NO_CONTENT", .noContent)] {
            #expect(throws: expected) {
                try PhoneImageADBClient.readNotification { _, _ in try state(value, value: stateValue) }
            }
        }
        #expect(throws: PhoneNotificationError.changed) {
            try PhoneImageADBClient.readNotification { name, _ in name == "notification-content.json" ? content : try state(value, offset: -1) }
        }
    }
    @Test func privateCacheRoundtripRejectsLinksAndCanClearCorruption() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try fixture(picture: true)
        #expect(try PhoneNotificationStore.load(in: root) == nil)
        try PhoneNotificationStore.save(value, in: root)
        #expect(try PhoneNotificationStore.load(in: root) == value)
        let file = root.appendingPathComponent("sample.json")
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(throws: PhoneNotificationError.privateFile) { try PhoneNotificationStore.load(in: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try Data("invalid".utf8).write(to: file)
        #expect(throws: PhoneNotificationError.invalid) { try PhoneNotificationStore.load(in: root) }
        try PhoneNotificationStore.clear(in: root)
        #expect(try PhoneNotificationStore.load(in: root) == nil)
        let other = root.appendingPathComponent("untouched.json"); try Data("unchanged".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        #expect(throws: PhoneNotificationError.privateFile) { try PhoneNotificationStore.load(in: root) }
        #expect(throws: PhoneNotificationError.privateFile) { try PhoneNotificationStore.save(value, in: root) }
        #expect(throws: PhoneNotificationError.privateFile) { try PhoneNotificationStore.clear(in: root) }
        #expect(try String(contentsOf: other, encoding: .utf8) == "unchanged")
    }
    actor Latch {
        private var release: CheckedContinuation<Void, Never>?
        private var entered: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { release = $0; entered?.resume(); entered = nil } }
        func started() async { if release == nil { await withCheckedContinuation { entered = $0 } } }
        func open() { release?.resume(); release = nil }
    }
    @Test func cancellationRefusesLateImportAndNeverChangesRealSettings() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try fixture(); let latch = Latch()
        let setting = UserDefaults.standard.string(forKey: "phoneImageEndpoint")
        let model = PhoneNotificationModel(directory: root, persistEndpoint: false) { _ in await latch.wait(); return value }
        model.endpoint = ""
        let task = Task { await model.readFromPhone() }; await latch.started()
        model.cancel(); await latch.open(); await task.value
        let cancelledCache = try PhoneNotificationStore.load(in: root)
        #expect(model.snapshot == nil && !model.busy && cancelledCache == nil)
        let success = PhoneNotificationModel(directory: root, persistEndpoint: false) { _ in value }
        success.endpoint = ""; await success.readFromPhone()
        #expect(success.snapshot == value && !success.busy)
        success.clear(); let clearedCache = try PhoneNotificationStore.load(in: root)
        #expect(success.snapshot == nil && clearedCache == nil)
        #expect(UserDefaults.standard.string(forKey: "phoneImageEndpoint") == setting)
    }
    @Test func actualNativeFixtureRendersPictureVersusEmpty() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let model = PhoneNotificationModel(directory: root, persistEndpoint: false)
        func orangeSamples() throws -> Int {
            let view = NSHostingView(rootView: PhoneNotificationView(model: model))
            view.frame = NSRect(x: 0, y: 0, width: 680, height: 900); view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
            let image = try #require(bitmap.cgImage); let width = image.width, height = image.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            try pixels.withUnsafeMutableBytes { storage in
                let context = try #require(CGContext(data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return stride(from: 0, to: pixels.count, by: 40).filter { offset in pixels[offset] > 200 && pixels[offset+1] > 75 && pixels[offset+1] < 205 && pixels[offset+2] < 50 }.count
        }
        #expect(try orangeSamples() == 0)
        model.snapshot = try fixture(picture: true); #expect(try orangeSamples() > 100)
        model.snapshot = try fixture(); #expect(try orangeSamples() == 0)
    }
}
