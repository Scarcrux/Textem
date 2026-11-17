import AppKit
import Foundation
import SwiftUI
import WebKit
import XCTest
@testable import scarcrux_textem

@MainActor final class OfflineModeTests: XCTestCase {
    // XCTest cases run before Swift Testing transport suites. Restore the exact
    // preference, including absence, without leaking mode changes to other cases.
    private func withMode(_ value: Bool, body: () async throws -> Void) async rethrows {
        let original = OfflineMode.preferences.object(forKey: "offlineMode")
        OfflineMode.preferences.set(value, forKey: "offlineMode")
        defer {
            if let original { OfflineMode.preferences.set(original, forKey: "offlineMode") }
            else { OfflineMode.preferences.removeObject(forKey: "offlineMode") }
        }
        try await body()
    }
    private func model(_ account: UUID, root: URL) -> OfflineLibraryModel {
        OfflineLibraryModel(accountID: account, previews: root.appendingPathComponent("previews"),
            history: root.appendingPathComponent("history"), pictures: root.appendingPathComponent("pictures"))
    }
    func testColdStartTransitionsAndAccountIsolationWithoutDeletingCaches() async throws {
        let root = try PhoneImageTests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let context = PhoneHistoryTests().context
        try PhoneHistoryStore.link(PhoneHistoryTests().fixture(), to: context, in: root.appendingPathComponent("history"))
        let file = root.appendingPathComponent("history/history.json"), before = try Data(contentsOf: file)
        let account = Account(id: context.accountID, name: "Synthetic account", storeIdentifier: nil)
        let other = Account(name: "Other synthetic account", storeIdentifier: UUID())
        let store = WKWebsiteDataStore.nonPersistent()
        try await withMode(true) {
            let controller = MainWindowController(account: account, storeForAccount: { _ in store },
                initialURL: URL(string: "about:blank"), offlineLibrary: { self.model($0, root: root) })
            defer { NotificationCenter.default.removeObserver(controller); controller.close() }
            XCTAssertFalse(controller.webViewController.isViewLoaded)
            XCTAssertEqual(controller.offlineModel?.saved.selectedHistory?.snapshot.messages.count, 3)
            XCTAssertTrue(OfflineDiagnostics.collect(controller).localLibraryPresented)
            controller.switchTo(other)
            XCTAssertFalse(controller.webViewController.isViewLoaded)
            XCTAssertTrue(controller.offlineModel?.saved.histories.isEmpty == true)
            controller.switchTo(account)
            OfflineMode.setEnabled(false)
            XCTAssertNil(controller.offlineModel)
            XCTAssertTrue(controller.webViewController.isViewLoaded)
            let browser = try XCTUnwrap(controller.webViewController.view.subviews.compactMap { $0 as? WKWebView }.first)
            XCTAssertTrue(browser.configuration.websiteDataStore === store)
            OfflineMode.setEnabled(true)
            XCTAssertFalse(controller.webViewController.isViewLoaded)
            XCTAssertEqual(controller.offlineModel?.saved.selectedHistory?.snapshot.messages.count, 3)
            XCTAssertEqual(try Data(contentsOf: file), before)
        }
    }
    func testOfflineRejectsPhoneAccessBeforeCredentialsCommandsOrNetwork() async throws {
        await withMode(true) {
            let journal = CompanionJournalTransport(load: { XCTFail("Offline read accessed credentials"); return nil })
            do { _ = try await journal.fetch(developerEndpoint: ""); XCTFail("Offline journal was allowed") }
            catch { XCTAssertTrue(error is OfflineMode.Unavailable) }
            let history = CompanionHistoryTransport(load: { XCTFail("Offline history accessed credentials"); return nil })
            do { _ = try await history.fetch(); XCTFail("Offline history was allowed") }
            catch { XCTAssertTrue(error is OfflineMode.Unavailable) }
            do { _ = try PhoneImageCommand.run(URL(fileURLWithPath: "/usr/bin/false"), []); XCTFail("Offline process was allowed") }
            catch { XCTAssertTrue(error is OfflineMode.Unavailable) }
            let report = await PhoneRecoveryCheck.collect(load: { XCTFail("Offline diagnostic accessed credentials"); return nil }, records: { [] })
            XCTAssertEqual(report.state, .offline)
        }
        try await withMode(false) { XCTAssertNoThrow(try OfflineMode.requireOnline()) }
    }
    func testOfflineMenuExists() {
        let menu = MainMenu.build(appName: "Textem")
        XCTAssertEqual(menu.item(withTitle: "View")?.submenu?.item(withTitle: "Offline Mode")?.action,
            #selector(AppDelegate.toggleOfflineMode(_:)))
    }
    func testRenderPopulatedEmptyAndPictureLibraries() throws {
        let root = try PhoneImageTests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let context = PhoneHistoryTests().context
        try PhoneHistoryStore.link(PhoneHistoryTests().fixture(), to: context, in: root.appendingPathComponent("history"))
        let (manifest, png) = try PhoneImageTests().fixture()
        _ = try PhoneImageStore.importImage(manifest: manifest, png: png, in: root.appendingPathComponent("pictures"))
        for variant in ["history", "empty", "pictures"] {
            let source = variant == "empty" ? root.appendingPathComponent("empty") : root
            let model = model(context.accountID, root: source)
            model.showPictures = variant == "pictures"
            for width: CGFloat in [600, 1000] {
                for dark in [false, true] {
                    let view = NSHostingView(rootView: OfflineLibraryView(model: model, goOnline: {})
                        .frame(width: width, height: 780))
                    view.frame = NSRect(x: 0, y: 0, width: width, height: 780)
                    let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.contentView = view
                    view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    var colors = Set<Int>()
                    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 5) {
                        for x in stride(from: 0, to: bitmap.pixelsWide, by: 5) {
                            if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                                colors.insert(Int(c.redComponent * 255) << 16 | Int(c.greenComponent * 255) << 8 | Int(c.blueComponent * 255))
                            }
                        }
                    }
                    XCTAssertGreaterThan(colors.count, 20)
                    if let folder = ProcessInfo.processInfo.environment["TEXTEM_OFFLINE_SNAPSHOTS"] {
                        let file = URL(fileURLWithPath: folder).appendingPathComponent("offline-\(variant)-\(Int(width))-\(dark ? "dark" : "light").png")
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
                    }
                    window.contentView = nil; view.removeFromSuperview()
                }
            }
        }
    }
}
