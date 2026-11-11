import Foundation
import CryptoKit
import Testing
import NativeAutoFillCore
import AppKit
import SwiftUI
@testable import scarcrux_textem

@Suite("Native AutoFill distribution policy")
struct DeveloperIDPolicyTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let signer = Data("synthetic certificate, not a signing identity".utf8)
    var pin: String { Insecure.SHA1.hash(data: signer).map { String(format: "%02X", $0) }.joined() }
    func entitlements(_ id: String) -> [String: Any] {
        ["com.apple.application-identifier": DeveloperIDPolicy.team + "." + id,
         "com.apple.developer.team-identifier": DeveloperIDPolicy.team,
         "com.apple.developer.authentication-services.autofill-credential-provider": true,
         "keychain-access-groups": [DeveloperIDPolicy.team + ".com.scarcrux.textem.codes"],
         "com.apple.security.app-sandbox": id.hasSuffix("codeprovider")]
    }
    func profile(_ id: String) -> [String: Any] {
        ["TeamIdentifier": [DeveloperIDPolicy.team], "Entitlements": entitlements(id),
         "CreationDate": now.addingTimeInterval(-1), "ExpirationDate": now.addingTimeInterval(3600),
         "DeveloperCertificates": [signer], "Platform": ["OSX"], "ProvisionsAllDevices": true]
    }
    func accepted(_ profile: [String: Any], _ entitlements: [String: Any], _ id: String) -> Bool {
        DeveloperIDPolicy.accepts(profile: profile, entitlements: entitlements, bundleID: id, signer: signer, expectedPin: pin, now: now)
    }
    @Test func exactDistributionHostAndSandboxedProviderPass() {
        for id in ["com.scarcrux.textem", "com.scarcrux.textem.codeprovider"] {
            #expect(accepted(profile(id), entitlements(id), id))
            #expect(!DeveloperIDPolicy.accepts(profile: profile(id), entitlements: entitlements(id), bundleID: id,
                                              signer: signer, expectedPin: "WRONG", now: now))
        }
    }
    @Test func developmentExpiredFutureWrongPlatformAndCertificateProfilesFail() {
        let id = "com.scarcrux.textem"
        for (key, value): (String, Any) in [
            ("ProvisionsAllDevices", false), ("ProvisionsAllDevices", 1),
            ("ExpirationDate", now), ("CreationDate", now.addingTimeInterval(1)),
            ("Platform", ["iOS"]), ("DeveloperCertificates", [Data("different".utf8)]),
            ("TeamIdentifier", ["OTHERTEAM"])
        ] {
            var candidate = profile(id); candidate[key] = value
            #expect(!accepted(candidate, entitlements(id), id))
        }
    }
    @Test func extraGroupsDebugEntitlementsAndWrongIdentityFail() {
        let id = "com.scarcrux.textem"
        for (key, value): (String, Any) in [
            ("keychain-access-groups", [DeveloperIDPolicy.team + ".*"]),
            ("get-task-allow", true), ("com.apple.security.get-task-allow", true),
            ("com.apple.developer.authentication-services.autofill-credential-provider", 1),
            ("com.apple.application-identifier", DeveloperIDPolicy.team + ".other.app")
        ] {
            var candidate = entitlements(id); candidate[key] = value
            #expect(!accepted(profile(id), candidate, id))
        }
        let provider = "com.scarcrux.textem.codeprovider"
        var unsandboxed = entitlements(provider); unsandboxed["com.apple.security.app-sandbox"] = false
        #expect(!accepted(profile(provider), unsandboxed, provider))
    }
    @Test @MainActor func readyBuildExplainsOwnerProviderEnablement() async throws {
        let storage = NativeCodeVaultTests.Storage()
        let publisher = NativeCodeVaultTests.Publisher()
        publisher.failure = NativeCodeSetupError.notEnabled
        let model = NativeAutoFillCoordinator(vault: CodeVault(storage: storage), publisher: publisher,
                                               available: true, accountExists: { _ in false })
        await model.setEnabled(true)
        #expect(model.available && model.status.contains("System Settings") && model.status.contains("not active"))
        let view = NSHostingView(rootView: SettingsView(nativeCodes: model))
        view.appearance = NSAppearance(named: .aqua)
        view.frame = NSRect(x: 0, y: 0, width: 460, height: 740); view.layoutSubtreeIfNeeded()
        if let path = ProcessInfo.processInfo.environment["TEXTEM_AUTOFILL_READY_FIXTURE"] {
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: path))
        }
        await model.setEnabled(false)
        #expect(storage.data == nil)
    }
}
