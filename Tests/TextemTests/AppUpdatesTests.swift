import CryptoKit
import Foundation
import Sparkle
import Testing
@testable import scarcrux_textem

@MainActor final class FixtureUpdateEngine: AppUpdateEngine {
    var changed: (@MainActor () -> Void)?
    var canCheck = true
    var writes = 0
    var automaticChecks = false { didSet { writes += 1; changed?() } }
    var starts = 0
    var checks = 0
    var failStart = false
    func start() throws { starts += 1; if failStart { throw URLError(.unknown) } }
    func check() { checks += 1; canCheck = false; changed?() }
}

@Suite("Signed application updates", .serialized) @MainActor
struct AppUpdatesTests {
    static var info: [String: Any] {
        ["SUFeedURL": "https://updates.example.invalid/appcast.xml",
         "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString()]
    }
    static func fixture() -> AppUpdates {
        let model = AppUpdates(configuration: { try AppUpdateConfiguration(info: info) }, makeEngine: { FixtureUpdateEngine() })
        model.start(); return model
    }
    @Test func startsOnceWithoutCheckingOrWritingPreferencesAndHonorsBusyState() {
        let engine = FixtureUpdateEngine()
        let model = AppUpdates(configuration: { try AppUpdateConfiguration(info: Self.info) }, makeEngine: { engine })
        model.start(); model.start()
        #expect(model.started && model.canCheck && !model.automaticChecks)
        #expect(engine.starts == 1 && engine.checks == 0 && engine.writes == 0)
        model.setAutomaticChecks(true)
        #expect(model.automaticChecks && engine.writes == 1)
        model.setAutomaticChecks(true); #expect(engine.writes == 1)
        #expect(model.check() && engine.checks == 1 && !model.canCheck)
        #expect(!model.check() && engine.checks == 1)
        engine.canCheck = true; engine.changed?(); #expect(model.canCheck)
    }
    @Test func invalidConfigurationNeverCreatesOrStartsAnEngine() {
        for changes in [["SUFeedURL": "http://updates.example.invalid/appcast.xml"],
                        ["SUFeedURL": "https://user:password@updates.example.invalid/appcast.xml"],
                        ["SUFeedURL": "https://updates.example.invalid/appcast.xml#fragment"],
                        ["SUFeedURL": "https://updates.example.invalid/appcast.xml?token=example"],
                        ["SUFeedURL": "file:///tmp/appcast.xml"],
                        ["SUPublicEDKey": "not-a-key"],
                        ["SUPublicEDKey": Data(repeating: 1, count: 31).base64EncodedString()]] {
            var info = Self.info
            for (key, value) in changes { info[key] = value }
            let configured = info
            let model = AppUpdates(configuration: { try AppUpdateConfiguration(info: configured) }, makeEngine: {
                Issue.record("Invalid configuration reached Sparkle"); return FixtureUpdateEngine()
            })
            model.start(); model.setAutomaticChecks(true)
            #expect(!model.started && !model.canCheck && !model.check() && !model.automaticChecks)
            #expect(model.status.contains("unavailable"))
        }
        #expect(throws: AppUpdateConfiguration.Invalid.feed) { try AppUpdateConfiguration(info: [:]) }
    }
    @Test func startupFailureDoesNotExposeReadyControls() {
        let engine = FixtureUpdateEngine(); engine.failStart = true
        let model = AppUpdates(configuration: { try AppUpdateConfiguration(info: Self.info) }, makeEngine: { engine })
        model.start()
        #expect(!model.started && !model.canCheck && !model.check() && engine.checks == 0)
    }
    @Test func updateDiagnosticHasOnlyStateAndRefusesUnsafePaths() throws {
        let model = Self.fixture(), report = UpdateDiagnostics.collect(model)
        #expect(report.started && report.canCheck && !report.automaticChecks)
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        #expect(!encoded.contains("SUPublicEDKey") && !encoded.contains("https://") && !encoded.contains("example.invalid"))
        let root = try PhoneImageTests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("diagnostics")
        try UpdateDiagnostics.save(report, in: directory)
        let file = directory.appendingPathComponent("app-update-check.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        #expect(throws: PhoneNotificationError.privateFile) { try UpdateDiagnostics.save(report, in: directory) }
        let symlink = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: directory)
        #expect(throws: PhoneNotificationError.privateFile) { try UpdateDiagnostics.save(report, in: symlink) }
    }
    @Test func productionDefaultsRequireSignedUpdatesAndDoNotOptInForTheUser() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let info = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let config = try AppUpdateConfiguration(info: info)
        #expect(config.feed.absoluteString == "https://textem.scarcrux.com/updates/appcast.xml")
        for key in ["SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed"] { #expect(info[key] as? Bool == true) }
        // Checks run on their own (daily, only while Textem is open); installing
        // always asks. No system profile or feed JavaScript.
        #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
        #expect(info["SUScheduledCheckInterval"] as? Int == 86400)
        for key in ["SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates", "SUEnableSystemProfiling", "SUEnableJavaScript"] {
            #expect(info[key] as? Bool == false)
        }
        #expect(info["SUSignedFeedFailureExpirationInterval"] as? Int == 0)
        #expect(Bundle(for: SPUStandardUpdaterController.self).object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "2.10.0")
    }
    @Test func actualSigningToolAcceptsOriginalAndRejectsChangedBytesAndWrongKey() throws {
        let root = try PhoneImageTests().temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/artifacts/sparkle/Sparkle/bin")
        func run(_ arguments: [String]) throws -> (Int32, Data) {
            let process = Process(); process.executableURL = tools.appendingPathComponent("sign_update"); process.arguments = arguments
            let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return (process.terminationStatus, data)
        }
        let key = Curve25519.Signing.PrivateKey(), other = Curve25519.Signing.PrivateKey()
        let file = root.appendingPathComponent("synthetic-payload.bin"), keyFile = root.appendingPathComponent("synthetic-key")
        try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: keyFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        let original = Data("Synthetic update signature control".utf8); try original.write(to: file)
        let signed = try run(["--ed-key-file", keyFile.path, "-p", file.path])
        #expect(signed.0 == 0)
        let signature = try #require(String(data: signed.1, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(key.publicKey.isValidSignature(try #require(Data(base64Encoded: signature)), for: original))
        #expect(try run(["--ed-key-file", keyFile.path, "--verify", file.path, signature]).0 == 0)
        try Data("Changed update signature control".utf8).write(to: file)
        #expect(try run(["--ed-key-file", keyFile.path, "--verify", file.path, signature]).0 != 0)
        try original.write(to: file)
        try Data(other.rawRepresentation.base64EncodedString().utf8).write(to: keyFile)
        #expect(try run(["--ed-key-file", keyFile.path, "--verify", file.path, signature]).0 != 0)
        try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: keyFile)
        let feed = root.appendingPathComponent("synthetic-appcast.xml")
        try Data("<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>Synthetic original feed</title></channel></rss>".utf8).write(to: feed)
        #expect(try run(["--ed-key-file", keyFile.path, "--verify", feed.path]).0 != 0)
        #expect(try run(["--ed-key-file", keyFile.path, feed.path]).0 == 0)
        #expect(try run(["--ed-key-file", keyFile.path, "--verify", feed.path]).0 == 0)
        let altered = try String(contentsOf: feed, encoding: .utf8).replacingOccurrences(of: "Synthetic original feed", with: "Synthetic modified feed")
        try Data(altered.utf8).write(to: feed)
        #expect(try run(["--ed-key-file", keyFile.path, "--verify", feed.path]).0 != 0)
    }
}
