// Read-only artifact verification. No profile contents, device IDs, certificate
// subjects, credentials, message data, or Keychain items are printed.
import Foundation
import Security

enum Refused: Error { case check(String) }
func require(_ valid: Bool, _ reason: String) throws { if !valid { throw Refused.check(reason) } }
func run(_ binary: String, _ arguments: [String]) throws -> Data {
    let p = Process(); p.executableURL = URL(fileURLWithPath: binary); p.arguments = arguments
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    try require(p.terminationStatus == 0, "artifact command failed")
    return data
}
func object(_ data: Data) throws -> [String: Any] {
    guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw Refused.check("invalid artifact plist") }
    return value
}
func profile(_ url: URL) throws -> [String: Any] {
    try profileData(Data(contentsOf: url))
}
func profileData(_ data: Data) throws -> [String: Any] {
    try require(data.count <= 1_048_576, "oversized profile")
    var decoder: CMSDecoder?
    try require(CMSDecoderCreate(&decoder) == errSecSuccess, "CMS decoder")
    guard let decoder else { throw Refused.check("CMS decoder absent") }
    let updated = data.withUnsafeBytes { CMSDecoderUpdateMessage(decoder, $0.baseAddress!, data.count) }
    try require(updated == errSecSuccess && CMSDecoderFinalizeMessage(decoder) == errSecSuccess, "invalid CMS message")
    var status = CMSSignerStatus(rawValue: 0)!
    var trust: SecTrust?; var verify: OSStatus = -1
    try require(CMSDecoderCopySignerStatus(decoder, 0, SecPolicyCreateBasicX509(), true, &status, &trust, &verify) == errSecSuccess && status == .valid && verify == errSecSuccess, "profile CMS signature/trust refused")
    var content: CFData?
    try require(CMSDecoderCopyContent(decoder, &content) == errSecSuccess, "CMS content")
    guard let content else { throw Refused.check("CMS content absent") }
    return try object(content as Data)
}
func signing(_ url: URL) throws -> [String: Any] {
    var code: SecStaticCode?; var info: CFDictionary?
    try require(SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, "static code creation")
    guard let code else { throw Refused.check("static code absent") }
    try require(SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess, "strict signature")
    try require(SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess, "signing info")
    guard let value = info as? [String: Any] else { throw Refused.check("signing info absent") }
    return value
}
func requirement(_ url: URL) throws -> SecRequirement {
    var code: SecStaticCode?; var requirement: SecRequirement?
    try require(SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, "requirement code")
    guard let code else { throw Refused.check("requirement code absent") }
    try require(SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, "designated requirement")
    guard let requirement else { throw Refused.check("designated requirement absent") }
    return requirement
}
func requirementText(_ value: SecRequirement) throws -> String {
    var text: CFString?
    try require(SecRequirementCopyString(value, [], &text) == errSecSuccess, "requirement text")
    guard let text else { throw Refused.check("requirement text absent") }
    return text as String
}

do {
    let args = CommandLine.arguments
    if args.count == 3 && args[1] == "--profile-control" {
        let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        _ = try profileData(data)
        guard let xmlStart = data.range(of: Data("<?xml".utf8)),
              let xmlEnd = data.range(of: Data("</plist>".utf8)),
              let marker = data.range(of: Data("<string>".utf8)), marker.upperBound < xmlEnd.lowerBound,
              data[marker.upperBound] >= 32, data[marker.upperBound] <= 126,
              data[marker.upperBound] != 60, data[marker.upperBound] != 38 else { throw Refused.check("profile control payload not located") }
        var changed = data
        changed[marker.upperBound] = changed[marker.upperBound] == 65 ? 66 : 65
        // The changed signed content remains a valid plist. A parser failure
        // alone cannot satisfy this cryptographic negative control.
        _ = try object(changed.subdata(in: xmlStart.lowerBound..<xmlEnd.upperBound))
        var reason: String?
        do { _ = try profileData(changed) }
        catch Refused.check(let value) { reason = value }
        catch { reason = "unexpected control error" }
        try require(reason == "profile CMS signature/trust refused", "CMS tamper control accepted or failed for the wrong reason")
        print("profile_control_original=PASS cms_content_tamper=REFUSED owner_profiles_unchanged=true")
        exit(0)
    }
    if args.count == 4 && args[1] == "--registration" {
        let app = URL(fileURLWithPath: args[2])
        let deviceData = try Data(contentsOf: URL(fileURLWithPath: args[3]))
        guard let devices = try JSONSerialization.jsonObject(with: deviceData) as? [[String: Any]] else { throw Refused.check("device inventory invalid") }
        let macs = devices.filter { $0["platform"] as? String == "com.apple.platform.macosx" && $0["simulator"] as? Bool == false }
        guard macs.count == 1, let macID = macs.first?["identifier"] as? String else { throw Refused.check("current Mac inventory ambiguous") }
        for (index, bundle) in [app, app.appendingPathComponent("Contents/PlugIns/TextemCodeProvider.appex")].enumerated() {
            _ = try signing(bundle)
            let value = try profile(bundle.appendingPathComponent("Contents/embedded.provisionprofile"))
            let id = index == 0 ? "com.scarcrux.textem" : "com.scarcrux.textem.codeprovider"
            let deviceIDs = value["ProvisionedDevices"] as? [String] ?? []
            try require(AutoFillProvisioning.authorizes(value, bundleID: id, teamID: DeveloperIDPolicy.team, now: Date()) && deviceIDs.contains(where: { $0.lowercased() == macID.lowercased() }), "Mac/capability not authorized by target profile")
        }
        print("current_mac_in_both_signed_target_profiles=PASS device_identifiers_not_printed=true")
        exit(0)
    }
    try require(args.count == 4, "usage: verify candidate.app installed.app expected-build")
    let app = URL(fileURLWithPath: args[1]), installed = URL(fileURLWithPath: args[2])
    let expectedBuild = args[3]
    guard let version = Int(expectedBuild) else { throw Refused.check("invalid expected build") }
    _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    let originalRequirement = try requirement(installed)
    try require(try requirementText(requirement(app)) == requirementText(originalRequirement), "installed designated requirement changed")
    var candidateCode: SecStaticCode?
    try require(SecStaticCodeCreateWithPath(app as CFURL, [], &candidateCode) == errSecSuccess, "requirement target")
    guard let candidateCode else { throw Refused.check("requirement target absent") }
    try require(SecStaticCodeCheckValidity(candidateCode, SecCSFlags(rawValue: kSecCSStrictValidate), originalRequirement) == errSecSuccess, "installed OS requirement refused candidate")
    let oldInfo = try object(Data(contentsOf: installed.appendingPathComponent("Contents/Info.plist")))
    try require(version > (Int(oldInfo["CFBundleVersion"] as? String ?? "") ?? Int.max), "build did not advance installed version")
    let bundles = [app, app.appendingPathComponent("Contents/PlugIns/TextemCodeProvider.appex")]
    for (index, bundle) in bundles.enumerated() {
        let id = index == 0 ? "com.scarcrux.textem" : "com.scarcrux.textem.codeprovider"
        let info = try object(Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")))
        try require(info["CFBundleIdentifier"] as? String == id && info["CFBundleVersion"] as? String == expectedBuild, "bundle identity/version mismatch")
        if index == 0 {
            let reference = try Data(contentsOf: URL(fileURLWithPath: "Resources/AppIcon.icns"))
            let icon = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Resources/AppIcon.icns"))
            try require(AppIconPolicy.accepts(iconFile: info["CFBundleIconFile"] as? String, data: icon, reference: reference), "app icon missing, corrupt or different from source")
            let framework = bundle.appendingPathComponent("Contents/Frameworks/Sparkle.framework")
            let license = try Data(contentsOf: URL(fileURLWithPath: ".build/artifacts/sparkle/Sparkle/LICENSE"))
            try require(try Data(contentsOf: bundle.appendingPathComponent("Contents/Resources/Sparkle-LICENSE")) == license, "updater license missing or changed")
            try require(framework.resolvingSymlinksInPath().path.hasPrefix(bundle.resolvingSymlinksInPath().path + "/"), "updater framework escaped app bundle")
            let frameworkInfo = try object(Data(contentsOf: framework.appendingPathComponent("Resources/Info.plist")))
            try require(frameworkInfo["CFBundleShortVersionString"] as? String == "2.10.0", "updater framework version mismatch")
            let frameworkSignature = try signing(framework)
            try require(frameworkSignature[kSecCodeInfoTeamIdentifier as String] as? String == DeveloperIDPolicy.team, "updater framework team mismatch")
            for arch in ["arm64", "x86_64"] { _ = try run("/usr/bin/lipo", [framework.appendingPathComponent("Sparkle").path, "-verify_arch", arch]) }
            let sourceInfo = try object(Data(contentsOf: URL(fileURLWithPath: "Resources/Info.plist")))
            for key in ["SUFeedURL", "SUPublicEDKey", "SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction", "SUEnableAutomaticChecks", "SUAllowsAutomaticUpdates", "SUEnableSystemProfiling"] {
                try require((info[key] as? NSObject)?.isEqual(sourceInfo[key]) == true, "updater policy differs from source")
            }
            print("updater_framework_signature_team_version_arches_and_policy=PASS")
        }
        guard let binary = info["CFBundleExecutable"] as? String, !binary.contains("/") else { throw Refused.check("invalid executable") }
        for arch in ["arm64", "x86_64"] { _ = try run("/usr/bin/lipo", [bundle.appendingPathComponent("Contents/MacOS/" + binary).path, "-verify_arch", arch]) }
        let signed = try signing(bundle)
        guard let entitlements = signed[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let certificates = signed[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first else { throw Refused.check("signer/entitlements absent") }
        let embedded = try profile(bundle.appendingPathComponent("Contents/embedded.provisionprofile"))
        try require(DeveloperIDPolicy.accepts(profile: embedded, entitlements: entitlements, bundleID: id,
                                             signer: SecCertificateCopyData(leaf) as Data, now: Date()), "Developer ID certificate/profile/entitlement policy refused")
        print("target=\(index == 0 ? "host" : "provider") signature_profile_capabilities_arches_version=PASS")
    }
    print("installed_designated_requirement=UNCHANGED deployment_candidate=PASS notarization_not_assessed=true")
} catch Refused.check(let reason) {
    print("candidate=REFUSED reason=\(reason)"); exit(1)
} catch { print("candidate=REFUSED reason=artifact_read_failed"); exit(1) }
