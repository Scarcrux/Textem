import Foundation

public enum AutoFillProvisioning {
    public static func authorizes(_ profile: [String: Any], bundleID: String, teamID: String, now: Date) -> Bool {
        guard let expiration = profile["ExpirationDate"] as? Date, expiration > now,
              let teams = profile["TeamIdentifier"] as? [String], teams.contains(teamID),
              let entitlements = profile["Entitlements"] as? [String: Any],
              let enabled = entitlements["com.apple.developer.authentication-services.autofill-credential-provider"] as? NSNumber,
              CFGetTypeID(enabled) == CFBooleanGetTypeID(), enabled.boolValue else { return false }
        let identifier = entitlements["com.apple.application-identifier"] as? String ?? entitlements["application-identifier"] as? String
        // Deliberately require exact IDs, not wildcard/unrelated provisioning.
        return identifier == teamID + "." + bundleID
    }
}
