import AppKit
import Foundation
import SwiftUI

enum OfflineDiagnostics {
    struct Report: Encodable {
        let schema = 1
        let kind = "OFFLINE_MODE_CHECK"
        let checkedAt = Date()
        let enabled: Bool
        let webViewLoaded: Bool
        let localLibraryPresented: Bool
        let windowVisible: Bool
        let historyRecords: Int
        let historyRows: Int
        let previewRecords: Int
        let importedPictures: Int
    }
    @MainActor static func collect(_ controller: MainWindowController) -> Report {
        let model = controller.offlineModel
        let presented = (controller.window?.contentViewController as? NSHostingController<OfflineLibraryView>)?.rootView.model
        return Report(enabled: OfflineMode.enabled, webViewLoaded: controller.webViewController.isViewLoaded,
            localLibraryPresented: model != nil && presented === model,
            windowVisible: controller.window?.isVisible == true,
            historyRecords: model?.saved.histories.count ?? 0,
            historyRows: model?.saved.histories.reduce(0) { $0 + $1.snapshot.messages.count } ?? 0,
            previewRecords: model?.saved.records.count ?? 0, importedPictures: model?.images.images.count ?? 0)
    }
    static func save(_ report: Report) throws {
        let directory = PhoneRecoveryCheck.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              attributes[.type] as? FileAttributeType == .typeDirectory else { throw PhoneNotificationError.privateFile }
        let file = directory.appendingPathComponent("offline-mode-check.json")
        if FileManager.default.fileExists(atPath: file.path) { _ = try PhoneImageStore.readPrivate(file, maximum: 4096) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(report)
        guard data.count <= 4096 else { throw PhoneNotificationError.invalid }
        try data.write(to: file, options: .atomic)
        guard chmod(file.path, 0o600) == 0 else { throw PhoneNotificationError.privateFile }
    }
}
