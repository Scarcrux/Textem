import AppKit
import Darwin
import Foundation
import ImageIO
import SwiftUI
import Testing
@testable import scarcrux_textem

@Suite("Explicit phone image handoff") @MainActor
struct PhoneImageTests {
    func fixture() throws -> (PhoneImageManifest, Data) {
        let pixels = Data((0..<48).flatMap { _ in [UInt8(255), 128, 0, 255] })
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(width: 8, height: 6, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let buffer = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(buffer, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let data = buffer as Data
        return (PhoneImageManifest(schema: 1, kind: "SHARED_IMAGE", id: UUID(),
            createdAtMS: Int64(Date().timeIntervalSince1970 * 1000), filename: "mac-image-0.png", mime: "image/png",
            width: 8, height: 6, bytes: data.count, sha256: PhoneImageManifest.digest(data)), data)
    }
    func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("textem-image-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }
    func json(_ manifest: PhoneImageManifest, changing key: String, to value: Any) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
        object[key] = value
        return try JSONSerialization.data(withJSONObject: object)
    }
    @Test func realPNGAndSyntheticDiscriminate() throws {
        let (manifest, png) = try fixture()
        try PhoneImageManifest.parse(JSONEncoder().encode(manifest)).validatePNG(png)
        #expect(throws: PhoneImageError.invalid) {
            try PhoneImageManifest.parse(json(manifest, changing: "kind", to: "SYNTHETIC_IMAGE"))
        }
        #expect(throws: PhoneImageError.invalid) {
            try PhoneImageManifest.parse(json(manifest, changing: "sha256", to: String(repeating: "0", count: 64))).validatePNG(png)
        }
    }
    @Test func invalidManifestAndContentAreRejected() throws {
        let (manifest, png) = try fixture()
        for (key, value) in [("filename", "../private.png" as Any), ("mime", "image/jpeg"), ("width", 2049),
                             ("width", true), ("bytes", 9_000_000), ("uri", "PRIVATE_SENTINEL"),
                             ("created_at_ms", 0), ("created_at_ms", Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000)] {
            #expect(throws: PhoneImageError.invalid) { try PhoneImageManifest.parse(json(manifest, changing: key, to: value)) }
        }
        #expect(throws: PhoneImageError.invalid) { try manifest.validatePNG(Data(png.dropLast(20))) }
        #expect(throws: PhoneImageError.invalid) {
            try PhoneImageManifest.parse(json(manifest, changing: "width", to: 7)).validatePNG(png)
        }
    }
    @Test func privateLibraryRoundtripDedupAndDeletion() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let (manifest, png) = try fixture()
        let image = try PhoneImageStore.importImage(manifest: manifest, png: png, in: root)
        #expect(try PhoneImageStore.load(in: root) == [image])
        #expect(try PhoneImageStore.imageData(image, in: root) == png)
        #expect(try PhoneImageStore.importImage(manifest: manifest, png: png, in: root).id == image.id)
        #expect(try PhoneImageStore.load(in: root).count == 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(image.filename).path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        try PhoneImageStore.remove(image, in: root)
        #expect(try PhoneImageStore.load(in: root).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(image.filename).path))
    }
    @Test func unsafeFilesAndSymlinksAreRejected() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let (manifest, png) = try fixture()
        let image = try PhoneImageStore.importImage(manifest: manifest, png: png, in: root)
        let file = root.appendingPathComponent(image.filename)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(throws: PhoneImageError.privateFile) { try PhoneImageStore.imageData(image, in: root) }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("index.json"))
        #expect(throws: PhoneImageError.privateFile) { try PhoneImageStore.imageData(image, in: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root.appendingPathComponent("index.json").path)
        #expect(throws: PhoneImageError.privateFile) { try PhoneImageStore.load(in: root) }
    }
    @Test func invalidImageCannotCreateLibraryEntry() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let (manifest, _) = try fixture()
        #expect(throws: PhoneImageError.invalid) { try PhoneImageStore.importImage(manifest: manifest, png: Data("not PNG".utf8), in: root) }
        #expect(try PhoneImageStore.load(in: root).isEmpty)
    }
    @Test func libraryCountAndByteCapsAreEnforced() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let (manifest, png) = try fixture()
        func writeIndex(count: Int, bytes: Int) throws {
            let images = (0..<count).map { _ in ImportedPhoneImage(id: UUID(), sourceID: UUID(),
                importedAt: Date(), width: 8, height: 6, bytes: bytes, sha256: String(repeating: "0", count: 64)) }
            struct Index: Encodable { let schema = 1; let images: [ImportedPhoneImage] }
            let url = root.appendingPathComponent("index.json")
            try JSONEncoder().encode(Index(images: images)).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        try writeIndex(count: 25, bytes: 8)
        #expect(throws: PhoneImageError.full) { try PhoneImageStore.importImage(manifest: manifest, png: png, in: root) }
        try writeIndex(count: 26, bytes: 8)
        #expect(throws: PhoneImageError.invalid) { try PhoneImageStore.load(in: root) }
        try writeIndex(count: 25, bytes: PhoneImageManifest.maximumBytes)
        #expect(throws: PhoneImageError.invalid) { try PhoneImageStore.load(in: root) }
        try writeIndex(count: 1, bytes: Int.max)
        #expect(throws: PhoneImageError.invalid) { try PhoneImageStore.load(in: root) }
    }
    @Test func endpointAndDeviceSelectionAreBounded() {
        #expect(PhoneImageADBClient.validEndpoint("192.168.2.3:44444"))
        #expect(PhoneImageADBClient.validEndpoint("10.2.3.4:1"))
        for endpoint in ["8.8.8.8:4444", "192.168.2.3:0", "192.168.2.3:70000", "010.2.3.4:4", "example.com:4", "192.168.1.2:4;bad"] {
            #expect(!PhoneImageADBClient.validEndpoint(endpoint))
        }
        let listing = "List of devices attached\nadb-example (2)._adb-tls-connect._tcp device model:Example\nemulator-5588 device\nother unauthorized\n"
        #expect(PhoneImageADBClient.authorizedDevices(Data(listing.utf8)) == ["adb-example (2)._adb-tls-connect._tcp"])
    }
    @Test func commandOutputAndTimeAreBounded() throws {
        #expect(throws: PhoneImageError.invalid) {
            try PhoneImageCommand.run(URL(fileURLWithPath: "/usr/bin/printf"), ["abcdefghij"], maximum: 3)
        }
        #expect(throws: PhoneImageError.timeout) {
            try PhoneImageCommand.run(URL(fileURLWithPath: "/bin/sleep"), ["2"], timeout: 0.05)
        }
    }
    @Test func equivalentTransportsPreferUSBOnlyAfterSameBootProof() throws {
        let listing = Data("192.168.2.3:44001 device\nfixture-usb device usb:1-1 model:Fixture\n".utf8)
        let boot = Data("00000000-0000-4000-8000-000000000001\n".utf8)
        var events: [String] = []
        let selected = try PhoneImageADBClient.selectAuthorizedDevice(listing, verifyTLS: { _ in events.append("TLS") }) {
            events.append($0 == "fixture-usb" ? "USB" : "wireless"); return boot
        }
        #expect(selected == "fixture-usb" && events == ["TLS", "wireless", "USB"])
        var probes = 0
        let single = try PhoneImageADBClient.selectAuthorizedDevice(Data("fixture-usb device usb:1-1\n".utf8),
            verifyTLS: { _ in probes += 1 }, readBootID: { _ in probes += 1; return boot })
        #expect(single == "fixture-usb" && probes == 0)
        let aliases = Data("adb-fixture._adb-tls-connect._tcp device\nfixture-usb device usb:1-1\nemulator-5554 device\nother unauthorized\noffline-phone offline\n".utf8)
        #expect(try PhoneImageADBClient.selectAuthorizedDevice(aliases, verifyTLS: { _ in }, readBootID: { _ in boot }) == "fixture-usb")
    }
    @Test func ambiguousTransportIdentityTLSAndCapsFailClosed() throws {
        let listing = Data("192.168.2.3:44001 device\nfixture-usb device usb:1-1\n".utf8)
        let boot = Data("00000000-0000-4000-8000-000000000001\n".utf8)
        for invalid in [Data("00000000-0000-4000-8000-000000000002".utf8), Data("null".utf8),
                        Data("00000000-0000-0000-0000-000000000000".utf8), Data(repeating: 0, count: 65)] {
            #expect(throws: PhoneImageError.ambiguousDevices) {
                try PhoneImageADBClient.selectAuthorizedDevice(listing, verifyTLS: { _ in }, readBootID: { $0 == "fixture-usb" ? invalid : boot })
            }
        }
        #expect(throws: PhoneImageError.ambiguousDevices) {
            try PhoneImageADBClient.selectAuthorizedDevice(listing, verifyTLS: { _ in }, readBootID: { _ in throw PhoneImageError.connection })
        }
        var queries = 0
        #expect(throws: PhoneImageError.tlsRequired) {
            try PhoneImageADBClient.selectAuthorizedDevice(listing, verifyTLS: { _ in throw PhoneImageError.tlsRequired },
                readBootID: { _ in queries += 1; return boot })
        }
        #expect(queries == 0)
        let many = Data((0..<5).map { "fixture-\($0) device usb:1-\($0)" }.joined(separator: "\n").utf8)
        for bad in [many, Data(repeating: 0, count: 32769)] {
            #expect(throws: PhoneImageError.ambiguousDevices) {
                try PhoneImageADBClient.selectAuthorizedDevice(bad, verifyTLS: { _ in queries += 1 }, readBootID: { _ in queries += 1; return boot })
            }
        }
        #expect(queries == 0)
        #expect(throws: PhoneImageError.noDevice) {
            try PhoneImageADBClient.selectAuthorizedDevice(Data("other unauthorized\n".utf8), verifyTLS: { _ in }, readBootID: { _ in boot })
        }
    }
    @Test func exactTLSAdvertisementDiscriminates() {
        let endpoint = "192.168.2.3:44444"
        let record = "adb-example (2)\t_adb-tls-connect._tcp\t\(endpoint)\n"
        #expect(PhoneImageADBClient.tlsService(Data(record.utf8), endpoint: endpoint)
            == "adb-example (2)._adb-tls-connect._tcp")
        for invalid in [record.replacingOccurrences(of: "_adb-tls-connect", with: "_adb"),
                        record.replacingOccurrences(of: "_adb-tls-connect", with: "_adb-tls-pairing"),
                        record.replacingOccurrences(of: endpoint, with: "192.168.2.3:44445"),
                        record.replacingOccurrences(of: "_adb-tls-connect._tcp", with: "_adb-tls-connect._tcp.evil"),
                        record + record, "malformed", record.replacingOccurrences(of: "adb-example (2)", with: "")]
        { #expect(PhoneImageADBClient.tlsService(Data(invalid.utf8), endpoint: endpoint) == nil) }
    }
    @Test func delayedTLSDiscoveryIsBounded() async throws {
        final class Lookup: @unchecked Sendable {
            let lock = NSLock(); var calls = 0
            func next(appears: Bool) -> Data {
                lock.withLock {
                    calls += 1
                    return Data((appears && calls >= 3 ? "adb-example\t_adb-tls-connect._tcp\t192.168.2.3:44444\n" : "").utf8)
                }
            }
        }
        let delayed = Lookup()
        let name = try await PhoneImageADBClient.discoverTLSService(endpoint: "192.168.2.3:44444", wait: {}) { delayed.next(appears: true) }
        #expect(name == "adb-example._adb-tls-connect._tcp" && delayed.calls == 3)
        let absent = Lookup()
        let missing = try await PhoneImageADBClient.discoverTLSService(endpoint: "192.168.2.3:44444", wait: {}) { absent.next(appears: false) }
        #expect(missing == nil && absent.calls == 8)
    }
    @Test func tlsWireControlsUseActualExchange() throws {
        func header(_ words: [UInt32]) -> Data {
            var data = Data()
            for word in words { var little = word.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
            return data
        }
        let stls: UInt32 = 0x534c5453
        let valid = header([stls, 0x01000000, 0, 0, 0, ~stls])
        #expect(PhoneImageTLS.isSTLS(valid))
        for words: [UInt32] in [[0x48545541, 0x01000000, 0, 0, 0, ~UInt32(0x48545541)],
                               [0x4e584e43, 0x01000000, 0, 0, 0, ~UInt32(0x4e584e43)],
                               [stls, 1, 0, 0, 0, ~stls], [stls, 0x01000000, 0, 1, 0, ~stls],
                               [stls, 0x01000000, 0, 0, 0, 0]] {
            #expect(!PhoneImageTLS.isSTLS(header(words)))
        }
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        _ = valid.withUnsafeBytes { Darwin.send(pair[1], $0.baseAddress!, $0.count, 0) }
        try PhoneImageTLS.exchange(pair[0])
        var received = [UInt8](repeating: 0, count: PhoneImageTLS.greeting.count)
        let count = Darwin.recv(pair[1], &received, received.count, 0)
        #expect(count == PhoneImageTLS.greeting.count && Data(received) == PhoneImageTLS.greeting)
        #expect(throws: PhoneImageError.tlsRequired) { try PhoneImageTLS.exchange(pair[0], timeout: 0.02) }
        _ = shutdown(pair[1], SHUT_WR)
        #expect(throws: PhoneImageError.tlsRequired) { try PhoneImageTLS.exchange(pair[0]) }
    }
    @Test func actualClientViewRendersImportedGraphic() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let (manifest, png) = try fixture()
        try PhoneImageStore.importImage(manifest: manifest, png: png, in: root)
        let model = PhoneImagesModel(directory: root)
        #expect(model.graphic != nil && model.images.count == 1)
        #expect(try orangeSamples(in: model) > 100)
    }
    func orangeSamples(in model: PhoneImagesModel) throws -> Int {
        model.endpoint = "" // Fixture rendering must not depend on owner connection preferences.
        let renderer = ImageRenderer(content: PhoneImagesView(model: model, onClose: {}).frame(width: 620, height: 720))
        #expect(renderer.nsImage != nil)
        #expect(renderer.nsImage!.size == NSSize(width: 620, height: 720))
        let cgImage = try #require(renderer.cgImage)
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var orangeSamples = 0
        for x in stride(from: 0, to: width, by: 10) {
            for y in stride(from: 0, to: height, by: 10) {
                let offset = (y * width + x) * 4
                if pixels[offset] > 200, pixels[offset + 1] > 75, pixels[offset + 1] < 205,
                   pixels[offset + 2] < 50 { orangeSamples += 1 }
            }
        }
        return orangeSamples
    }
    @Test func explicitBindingIsExactAccountAndRouteOnly() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let (manifest, png) = try fixture()
        let image = try PhoneImageStore.importImage(manifest: manifest, png: png, in: root)
        let account = UUID()
        let target = PhoneImageConversation(accountID: account, route: "route-A", label: "Private fixture label")
        let before = try Data(contentsOf: root.appendingPathComponent("index.json"))
        #expect(try PhoneImageStore.images(for: target, in: root).isEmpty)
        try PhoneImageStore.link(image, to: target, in: root)
        try PhoneImageStore.link(image, to: target, in: root)
        #expect(try PhoneImageStore.loadBindings(in: root).count == 1)
        #expect(try PhoneImageStore.images(for: target, in: root) == [image])
        #expect(try PhoneImageStore.images(for: PhoneImageConversation(accountID: UUID(), route: target.route, label: target.label), in: root).isEmpty)
        #expect(try PhoneImageStore.images(for: PhoneImageConversation(accountID: account, route: "route-B", label: target.label), in: root).isEmpty)
        #expect(try PhoneImageStore.images(for: PhoneImageConversation(accountID: account, route: target.route, label: "Renamed fixture"), in: root) == [image])
        let sidecar = root.appendingPathComponent("bindings.json")
        let serialized = try String(contentsOf: sidecar, encoding: .utf8)
        #expect(!serialized.contains(target.label) && !serialized.contains(target.route) && !serialized.contains(account.uuidString))
        #expect(try FileManager.default.attributesOfItem(atPath: sidecar.path)[.posixPermissions] as? Int == 0o600)
        #expect(try Data(contentsOf: root.appendingPathComponent("index.json")) == before)
        for route in ["", "route/other", "route?query", "route#fragment", "two words", String(repeating: "x", count: 513)] {
            #expect(PhoneImageConversation(accountID: account, route: route, label: "Example").key == nil)
        }
    }
    @Test func reassignmentRequiresUnlinkAndDeletionCleansBinding() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let (manifest, png) = try fixture()
        let image = try PhoneImageStore.importImage(manifest: manifest, png: png, in: root)
        let a = PhoneImageConversation(accountID: UUID(), route: "A", label: "Example")
        let b = PhoneImageConversation(accountID: a.accountID, route: "B", label: "Example")
        try PhoneImageStore.link(image, to: a, in: root)
        #expect(throws: PhoneImageError.alreadyLinked) { try PhoneImageStore.link(image, to: b, in: root) }
        try PhoneImageStore.unlink(image, in: root)
        #expect(try PhoneImageStore.images(for: a, in: root).isEmpty)
        #expect(try PhoneImageStore.imageData(image, in: root) == png)
        try PhoneImageStore.link(image, to: b, in: root)
        try PhoneImageStore.remove(image, in: root)
        #expect(try PhoneImageStore.loadBindings(in: root).isEmpty)
    }
    @Test func unsafeAndMalformedBindingsFailClosed() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let (manifest, png) = try fixture()
        let image = try PhoneImageStore.importImage(manifest: manifest, png: png, in: root)
        let context = PhoneImageConversation(accountID: UUID(), route: "A", label: "Example")
        try PhoneImageStore.link(image, to: context, in: root)
        let url = root.appendingPathComponent("bindings.json")
        let good = try Data(contentsOf: url)
        var object = try #require(JSONSerialization.jsonObject(with: good) as? [String: Any])
        let entry = try #require((object["bindings"] as? [[String: Any]])?.first)
        for invalid: [String: Any] in [
            ["schema": 2, "bindings": [entry]],
            ["schema": 1, "bindings": [entry, entry]],
            ["schema": 1, "bindings": (0..<26).map { _ in ["imageID": UUID().uuidString, "conversationKey": String(repeating: "0", count: 64)] }],
            ["schema": 1, "bindings": [["imageID": image.id.uuidString, "conversationKey": "bad"]]]
        ] {
            try JSONSerialization.data(withJSONObject: invalid).write(to: url)
            #expect(throws: PhoneImageError.invalid) { try PhoneImageStore.loadBindings(in: root) }
        }
        try Data(repeating: 0, count: 16385).write(to: url)
        #expect(throws: PhoneImageError.privateFile) { try PhoneImageStore.loadBindings(in: root) }
        object["privateText"] = "PRIVATE_SENTINEL"
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        #expect(throws: PhoneImageError.invalid) { try PhoneImageStore.images(for: context, in: root) }
        let model = PhoneImagesModel(directory: root)
        #expect(model.images.isEmpty && model.graphic == nil)
        try good.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(throws: PhoneImageError.privateFile) { try PhoneImageStore.images(for: context, in: root) }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: root.appendingPathComponent("index.json"))
        #expect(throws: PhoneImageError.privateFile) { try PhoneImageStore.link(image, to: context, in: root) }
    }
    @Test func linkingRevalidatesContextAfterAsyncCheck() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let (manifest, png) = try fixture()
        try PhoneImageStore.importImage(manifest: manifest, png: png, in: root)
        let context = PhoneImageConversation(accountID: UUID(), route: "A", label: "Example")
        let model = PhoneImagesModel(directory: root); model.setConversation(context)
        model.validateConversation = { _ in model.setConversation(nil); return true }
        await model.linkSelected(to: context)
        #expect(try PhoneImageStore.loadBindings(in: root).isEmpty)
        model.setConversation(context); model.validateConversation = { _ in false }
        await model.linkSelected(to: context)
        #expect(try PhoneImageStore.loadBindings(in: root).isEmpty)
        model.validateConversation = { _ in true }
        await model.linkSelected(to: context)
        #expect(try PhoneImageStore.loadBindings(in: root).count == 1)
    }
    @Test func conversationViewRendersOnlyItsExplicitlyLinkedGraphic() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let (manifest, png) = try fixture()
        let image = try PhoneImageStore.importImage(manifest: manifest, png: png, in: root)
        let context = PhoneImageConversation(accountID: UUID(), route: "A", label: "Example conversation")
        try PhoneImageStore.link(image, to: context, in: root)
        let history = try PhoneHistoryTests().fixture()
        let historyDirectory = root.appendingPathComponent("history")
        try PhoneHistoryStore.link(history, to: context, in: historyDirectory)

        let other = PhoneImageConversation(accountID: UUID(), route: "A", label: context.label)
        for selected in [context, other] {
            let model = PhoneConversationModel(context: selected, directory: root.appendingPathComponent("previews"),
                                               historyDirectory: historyDirectory, imageDirectory: root)
            let matches = selected == context
            #expect(model.pictures == (matches ? [image] : []))
            #expect((model.history != nil) == matches)

            for (width, appearance) in [(460, NSAppearance.Name.aqua), (720, .darkAqua)] {
                let hosting = WebViewController.overlayHost(PhoneConversationView(model: model, onClose: {}, onImages: {}))
                hosting.frame = CGRect(x: 0, y: 0, width: width, height: 720)
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = hosting
                hosting.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let graphic = stride(from: 0, to: bitmap.pixelsHigh, by: 10).contains { y in
                    stride(from: 0, to: bitmap.pixelsWide, by: 10).contains { x in
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                        // Window capture color profiles can shift absolute RGB values.
                        return color.redComponent - color.greenComponent > 0.18
                            && color.greenComponent - color.blueComponent > 0.18
                    }
                }
                #expect(graphic == matches)
                if matches, let folder = ProcessInfo.processInfo.environment["TEXTEM_TIMELINE_SNAPSHOTS"] {
                    let file = URL(fileURLWithPath: folder).appendingPathComponent("timeline-\(width).png")
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)
                }
                window.contentView = nil
            }
        }
    }

    @Test func timelineSortsSavedPicturesWithMessageDates() throws {
        let history = try PhoneHistoryTests().fixture()
        let picture = ImportedPhoneImage(id: UUID(), sourceID: UUID(),
            importedAt: Date(timeIntervalSince1970: Double(history.messages[0].timestampMS) / 1000 + 10),
            width: 8, height: 6, bytes: 10, sha256: "")
        let timeline = SavedPhoneTimeline(history: history, samples: [], pictures: [picture], showOriginalCaptures: false)
        #expect(timeline.items.map(\.id) == [
            "history-" + history.messages[0].id, "import-" + picture.id.uuidString,
            "history-" + history.messages[1].id, "history-" + history.messages[2].id,
        ])
    }

    @Test func conversationPictureActionsRevalidateAndUnlinkWithoutRemovingCopy() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let (manifest, png) = try fixture()
        let image = try PhoneImageStore.importImage(manifest: manifest, png: png, in: root)
        let context = PhoneImageConversation(accountID: UUID(), route: "A", label: "Example")
        try PhoneImageStore.link(image, to: context, in: root)
        let model = PhoneConversationModel(context: context, directory: root.appendingPathComponent("previews"),
                                           imageDirectory: root)
        await model.changePicture(image, removeMacCopy: true)
        #expect(try PhoneImageStore.images(for: context, in: root) == [image])
        model.validate = { $0 == context }
        await model.changePicture(image, removeMacCopy: false)
        #expect(model.pictures.isEmpty)
        #expect(try PhoneImageStore.imageData(image, in: root) == png)
        try PhoneImageStore.link(image, to: context, in: root)
        model.reload()
        await model.changePicture(image, removeMacCopy: true)
        #expect(model.pictures.isEmpty)
        #expect(try PhoneImageStore.load(in: root).isEmpty)
    }
}
