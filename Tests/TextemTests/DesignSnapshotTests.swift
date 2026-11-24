import AppKit
import SwiftUI
import XCTest
import NativeAutoFillCore
import NativeAutoFillProvider
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
        // The test runner has no app icon; views that show NSApp's icon (the
        // sign-in guide) would otherwise render a generic folder.
        if let icon = NSImage(contentsOfFile: "Resources/AppIcon.icns") { NSApplication.shared.applicationIconImage = icon }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("textem-design-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let codes = NativeAutoFillCoordinator(
            vault: CodeVault(storage: MemoryStorage()), publisher: NoPublisher(), available: true)
        let updates = AppUpdatesTests.fixture()
        updates.setAutomaticChecks(true)  // the shipped default (SUEnableAutomaticChecks)
        let unavailableUpdates = AppUpdates(configuration: { throw AppUpdateConfiguration.Invalid.key })
        unavailableUpdates.start()
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
        let connection = CompanionConnectionModel(load: { nil }, save: { _ in })
        let saved = SavedPhoneConversationsModel(accountID: context.accountID, directory: recoveredDirectory)
        let emptySaved = SavedPhoneConversationsModel(accountID: UUID(), directory: recoveredDirectory)
        let overlapDirectory = scratch.appendingPathComponent("overlap")
        let overlapSamples = try PhonePreviewPresentationTests().overlapSamples()
        try PhoneConversationStore.link(overlapSamples[0], to: context, in: overlapDirectory)
        try PhoneConversationStore.ingest(overlapSamples[1], for: context, in: overlapDirectory)
        let overlap = PhoneConversationModel(context: context, directory: overlapDirectory,
            endpoint: { "" }, fetch: { _ in throw PhoneImageError.noDevice })
        overlap.automatic = false
        let originals = PhoneConversationModel(context: context, directory: overlapDirectory,
            endpoint: { "" }, fetch: { _ in throw PhoneImageError.noDevice })
        originals.automatic = false; originals.showOriginalCaptures = true
        let savedOverlap = SavedPhoneConversationsModel(accountID: context.accountID, directory: overlapDirectory)

        let retrying = LoadErrorView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        retrying.present(message: "The Internet connection appears to be offline. Retrying in 4 seconds.", isRetrying: true)
        let failed = LoadErrorView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        failed.present(message: "The Internet connection appears to be offline.", isRetrying: false)
        let find = FindBar(frame: NSRect(x: 0, y: 0, width: 640, height: 40))

        for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            try render(NSHostingView(rootView: MigrationFollowUpView(
                notifications: suffix == "light" ? .notDetermined : .denied,
                showAutoFill: true, autoFillEnabled: false, launchAtLogin: .constant(false),
                showPhoneTools: true, onNotifications: {}, onAutoFill: {}, onDone: {})),
                "after-updating-\(suffix)", appearance, output)
            try render(NSHostingView(rootView: PhoneConversationView(model: overlap, onClose: {}, onImages: {}).frame(width: 760, height: 900)),
                       "phone-overlap-\(suffix)", appearance, output)
            try render(NSHostingView(rootView: PhoneConversationView(model: overlap, onClose: {}, onImages: {}).frame(width: 430, height: 720)),
                       "phone-overlap-narrow-\(suffix)", appearance, output)
            try render(NSHostingView(rootView: PhoneConversationView(model: originals, onClose: {}, onImages: {}).frame(width: 760, height: 900)),
                       "phone-original-captures-\(suffix)", appearance, output)
            try render(NSHostingView(rootView: SavedPhoneConversationsView(model: savedOverlap, onClose: {}).frame(width: 760, height: 900)),
                       "saved-overlap-\(suffix)", appearance, output)
            try render(NSHostingView(rootView: SavedPhoneConversationsView(model: saved, onClose: {}).frame(width: 760, height: 900)),
                       "saved-conversation-\(suffix)", appearance, output)
            try render(NSHostingView(rootView: SavedPhoneConversationsView(model: emptySaved, onClose: {}).frame(width: 760, height: 900)),
                       "saved-conversation-empty-\(suffix)", appearance, output)
            try render(NSHostingView(rootView: CodeShortcutPicker { _ in false }),
                       "code-shortcut-picker-\(suffix)", appearance, output)
            try render(NSHostingView(rootView: SettingsView(nativeCodes: codes, updates: updates)), "settings-\(suffix)", appearance, output)
            try render(NSHostingView(rootView: SettingsView(nativeCodes: codes, updates: updates)), "settings-scrolled-\(suffix)", appearance, output, scrollToBottom: true)
            try render(NSHostingView(rootView: SettingsView(nativeCodes: codes, updates: unavailableUpdates)), "settings-updates-unavailable-\(suffix)", appearance, output)
            try render(NSHostingView(rootView: CompanionConnectionView(model: connection, onChanged: {}, onClose: {})),
                       "phone-connection-\(suffix)", appearance, output)
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
            if #available(macOS 15, *) {
                let now = Date()
                let samples = [("482913", -20.0), ("7731", -95.0)].compactMap { code, age in
                    CodeSample(detection: .init(code: code, domain: nil), accountID: UUID(),
                               receivedAt: now.addingTimeInterval(age), consent: true)
                }
                let provider = CredentialProvider()
                provider.readSamples = { samples }; provider.now = { now }
                provider.prepareOneTimeCodeCredentialList(for: [])
                try render(provider.view, "autofill-list-\(suffix)", appearance, output, fitting: false)
                let empty = CredentialProvider()
                empty.readSamples = { [] }
                empty.prepareOneTimeCodeCredentialList(for: [])
                try render(empty.view, "autofill-empty-\(suffix)", appearance, output, fitting: false)
            }
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
                        _ output: URL, fitting: Bool = true, scrollToBottom: Bool = false) throws {
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
        if scrollToBottom {
            func scrollViews(_ node: NSView) -> [NSScrollView] {
                (node as? NSScrollView).map { [$0] } ?? node.subviews.flatMap(scrollViews)
            }
            let scroll = try XCTUnwrap(scrollViews(view).first { scroll in
                (scroll.documentView?.bounds.height ?? 0) > scroll.contentView.bounds.height
            }, "Settings must scroll within the bounded window")
            let document = try XCTUnwrap(scroll.documentView)
            let y = document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.height : document.bounds.minY
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        // TEXTEM_DESIGN_SNAPSHOT_SCALE=2 renders Retina-sharp images (for the website).
        let scale = Double(ProcessInfo.processInfo.environment["TEXTEM_DESIGN_SNAPSHOT_SCALE"] ?? "") ?? 1
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(backdrop.bounds.width * scale), pixelsHigh: Int(backdrop.bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = backdrop.bounds.size
        backdrop.cacheDisplay(in: backdrop.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent("\(name).png"))
        XCTAssertGreaterThan(bitmap.pixelsWide, 100, name)
        window.contentView = nil
        view.removeFromSuperview()
    }
}
