import AppKit
import Darwin
import Sparkle

/// Explicit startup diagnostic; reports state, never checks or installs updates.
enum UpdateDiagnostics {
    struct Report: Encodable {
        let schema = 1
        let kind = "APP_UPDATE_CHECK"
        var checkedAt = Date().timeIntervalSince1970
        let build: String
        let started: Bool
        let canCheck: Bool
        let automaticChecks: Bool
        let signedFeedRequired: Bool
        let signedArchiveRequired: Bool
        let silentInstallationDisabled: Bool
        let systemProfilingDisabled: Bool
        let embeddedFramework: Bool
        let frameworkVersion: String
    }
    @MainActor static func collect(_ updates: AppUpdates) -> Report {
        let info = Bundle.main.infoDictionary ?? [:]
        let framework = Bundle(for: SPUStandardUpdaterController.self)
        let embedded = framework.bundleURL.resolvingSymlinksInPath().path.hasPrefix(
            Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks").resolvingSymlinksInPath().path + "/")
        return Report(build: info["CFBundleVersion"] as? String ?? "unknown", started: updates.started,
            canCheck: updates.canCheck, automaticChecks: updates.automaticChecks,
            signedFeedRequired: info["SURequireSignedFeed"] as? Bool == true,
            signedArchiveRequired: info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
            silentInstallationDisabled: info["SUAllowsAutomaticUpdates"] as? Bool == false,
            systemProfilingDisabled: info["SUEnableSystemProfiling"] as? Bool == false,
            embeddedFramework: embedded, frameworkVersion: framework.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
    }
    static func save(_ report: Report, in directory: URL = PhoneRecoveryCheck.directory) throws {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw PhoneNotificationError.privateFile }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw PhoneNotificationError.privateFile }
        let file = directory.appendingPathComponent("app-update-check.json")
        if lstat(file.path, &info) == 0 { _ = try PhoneImageStore.readPrivate(file, maximum: 4096) }
        else if errno != ENOENT { throw PhoneNotificationError.privateFile }
        let data = try JSONEncoder().encode(report)
        guard data.count <= 4096 else { throw PhoneNotificationError.invalid }
        try data.write(to: file, options: .atomic)
        guard chmod(file.path, 0o600) == 0 else { throw PhoneNotificationError.privateFile }
    }
}
