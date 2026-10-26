import AppKit
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
    @Test func actualClientViewRendersImportedGraphic() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let (manifest, png) = try fixture()
        try PhoneImageStore.importImage(manifest: manifest, png: png, in: root)
        let model = PhoneImagesModel(directory: root)
        #expect(model.graphic != nil && model.images.count == 1)
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
        #expect(orangeSamples > 100) // A placeholder/background cannot satisfy the graphic control.
    }
}
