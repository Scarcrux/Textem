import AppKit
import Foundation
import NativeAutoFillCore
import Testing

@Suite("Dock icon packaging") @MainActor
struct DockIconPackagingTests {
    var source: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/AppIcon.icns")
    }
    @Test func iconPolicyAcceptsOriginalAndRejectsMissingCorruptAndUnsafe() throws {
        let data = try Data(contentsOf: source)
        #expect(AppIconPolicy.accepts(iconFile: "AppIcon", data: data, reference: data))
        #expect(AppIconPolicy.accepts(iconFile: "AppIcon.icns", data: data, reference: data))
        #expect(!AppIconPolicy.accepts(iconFile: "AppIcon", data: nil, reference: data))
        #expect(!AppIconPolicy.accepts(iconFile: "../AppIcon", data: data, reference: data))
        #expect(!AppIconPolicy.accepts(iconFile: nil, data: data, reference: data))
        let corrupt = Data("not an image".utf8)
        #expect(!AppIconPolicy.accepts(iconFile: "AppIcon", data: corrupt, reference: data))
        #expect(!AppIconPolicy.accepts(iconFile: "AppIcon", data: corrupt, reference: corrupt))
    }
    @Test func existingIconRendersWithoutRedrawingTheAsset() throws {
        let image = try #require(NSImage(contentsOf: source))
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 256, height: 256))
        context.flushGraphics()
        let data = try #require(rep.representation(using: .png, properties: [:]))
        #expect(data.count > 1000)
        if let path = ProcessInfo.processInfo.environment["TEXTEM_ICON_FIXTURE"] {
            try data.write(to: URL(fileURLWithPath: path))
        }
    }
}
