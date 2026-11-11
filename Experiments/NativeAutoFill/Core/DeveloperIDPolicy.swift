import Foundation
import CryptoKit

public enum DeveloperIDPolicy {
    public static let team = "K466Z7J2AS"
    public static let certificateSHA1 = "99842B5A6A3B15AEF88EC89CE9A1B67E46F4B9C8"
    public static func accepts(profile: [String: Any], entitlements: [String: Any], bundleID: String,
                               signer: Data, expectedPin: String = certificateSHA1, now: Date) -> Bool {
        let pin = Insecure.SHA1.hash(data: signer).map { String(format: "%02X", $0) }.joined()
        guard pin == expectedPin,
              AutoFillProvisioning.authorizes(profile, bundleID: bundleID, teamID: team, now: now),
              boolean(profile["ProvisionsAllDevices"]) == true,
              let certificates = profile["DeveloperCertificates"] as? [Data], certificates.contains(signer),
              let created = profile["CreationDate"] as? Date, created <= now,
              let platforms = profile["Platform"] as? [String], platforms.contains("OSX"),
              boolean(entitlements["com.apple.developer.authentication-services.autofill-credential-provider"]) == true,
              entitlements["com.apple.developer.team-identifier"] as? String == team,
              (entitlements["com.apple.application-identifier"] as? String ?? entitlements["application-identifier"] as? String) == team + "." + bundleID,
              let groups = entitlements["keychain-access-groups"] as? [String],
              groups == [team + ".com.scarcrux.textem.codes"],
              entitlements["get-task-allow"] == nil || boolean(entitlements["get-task-allow"]) == false,
              entitlements["com.apple.security.get-task-allow"] == nil || boolean(entitlements["com.apple.security.get-task-allow"]) == false else { return false }
        if bundleID == "com.scarcrux.textem.codeprovider" {
            return boolean(entitlements["com.apple.security.app-sandbox"]) == true
        }
        return bundleID == "com.scarcrux.textem"
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
