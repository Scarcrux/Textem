import AppKit
import SwiftUI
import XCTest
import NativeAutoFillCore
@testable import scarcrux_textem

// Renders Textem's native surfaces to PNG files so a design change can be
// reviewed by looking at it. Offscreen rendering needs neither Screen Recording
// nor Accessibility permission, which agents on this Mac do not have.
//
//   TEXTEM_DESIGN_SNAPSHOT_DIR=/tmp/textem-design swift test --filter DesignSnapshotTests
//
// Skipped unless the variable is set, so ordinary test runs write nothing.
@MainActor
final class DesignSnapshotTests: XCTestCase {
    private struct NoPublisher: CodeIndexPublishing {
        func replace(_ entries: [CodeIndexEntry]) async throws {}
    }

    private final class MemoryStorage: CodeStorage {
        private var data: Data?
        func read() throws -> Data? { data }
        func write(_ data: Data) throws { self.data = data }
        func delete() throws { data = nil }
    }

    func testRenderNativeSurfaces() throws {
        guard let path = ProcessInfo.processInfo.environment["TEXTEM_DESIGN_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set TEXTEM_DESIGN_SNAPSHOT_DIR to render design snapshots.")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("textem-design-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let codes = NativeAutoFillCoordinator(
            vault: CodeVault(storage: MemoryStorage()), publisher: NoPublisher(), available: true)
        let notification = PhoneNotificationModel(
            directory: scratch.appendingPathComponent("notification"), persistEndpoint: false,
            fetch: { _ in throw PhoneNotificationError.privateFile }, revokeCodes: { _ in })
        let images = PhoneImagesModel(directory: scratch.appendingPathComponent("images"))
        let context = PhoneImageConversation(accountID: UUID(), route: "synthetic-route", label: "Example delivery")
        let preview = try PhoneNotificationTests().fixture(picture: true)
        let recoveredDirectory = scratch.appendingPathComponent("recovered")
        try PhoneConversationStore.link(preview, to: context, in: recoveredDirectory)
        let recovered = PhoneConversationModel(context: context, directory: recoveredDirectory,
            endpoint: { "" }, fetch: { _ in throw PhoneImageError.noDevice })
        let unlinked = PhoneConversationModel(context: context, directory: scratch.appendingPathComponent("unlinked"),
            endpoint: { "" }, fetch: { _ in throw PhoneImageError.noDevice })

        let retrying = LoadErrorView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        retrying.present(message: "The Internet connection appears to be offline. Retrying in 4 seconds.", isRetrying: true)
        let failed = LoadErrorView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        failed.present(message: "The Internet connection appears to be offline.", isRetrying: false)
        let find = FindBar(frame: NSRect(x: 0, y: 0, width: 640, height: 40))

        for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            try render(NSHostingView(rootView: SettingsView(nativeCodes: codes)), "settings-\(suffix)", appearance, output)
            try render(NSHostingView(rootView: OnboardingView(onDone: {})), "onboarding-\(suffix)", appearance, output)
            try render(NSHostingView(rootView: PhoneNotificationView(model: notification).frame(width: 680, height: 780)),
                       "phone-notification-\(suffix)", appearance, output)
            try render(NSHostingView(rootView: PhoneImagesView(model: images, onClose: {}).frame(width: 760, height: 640)),
                       "phone-images-\(suffix)", appearance, output)
            try render(NSHostingView(rootView: PhoneConversationView(model: unlinked, onClose: {}, onImages: {}).frame(width: 760, height: 900)),
                       "phone-conversation-empty-\(suffix)", appearance, output)
            try render(NSHostingView(rootView: PhoneConversationView(model: recovered, onClose: {}, onImages: {}).frame(width: 760, height: 900)),
                       "phone-conversation-recovered-\(suffix)", appearance, output)
            try render(retrying, "load-retrying-\(suffix)", appearance, output, fitting: false)
            try render(failed, "load-failed-\(suffix)", appearance, output, fitting: false)
            try render(find, "find-bar-\(suffix)", appearance, output, fitting: false)
        }
    }

    // Fills with the window background so transparent SwiftUI roots are judged
    // against the colour they actually sit on, in the appearance under test.
    private final class Backdrop: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill(); bounds.fill()
        }
    }

    private func render(_ view: NSView, _ name: String, _ appearance: NSAppearance,
                        _ output: URL, fitting: Bool = true) throws {
        view.removeFromSuperview()
        if fitting { view.frame = NSRect(origin: .zero, size: view.fittingSize) }
        let backdrop = Backdrop(frame: view.frame)
        view.autoresizingMask = [.width, .height]
        backdrop.addSubview(view)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = backdrop
        backdrop.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let bitmap = try XCTUnwrap(backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds))
        backdrop.cacheDisplay(in: backdrop.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent("\(name).png"))
        XCTAssertGreaterThan(bitmap.pixelsWide, 100, name)
        window.contentView = nil
        view.removeFromSuperview()
    }
}
