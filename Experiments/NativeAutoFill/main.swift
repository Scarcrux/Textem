// Read-only, counts/booleans only. Never prints decoded profile contents,
// names, certificate subjects, device identifiers, or profile filenames.
import Foundation

let team = "K466Z7J2AS"
let roots = ["Library/MobileDevice/Provisioning Profiles", "Library/Developer/Xcode/UserData/Provisioning Profiles"]
let home = FileManager.default.homeDirectoryForCurrentUser
var profiles: [[String: Any]] = []
for root in roots {
    let files = (try? FileManager.default.contentsOfDirectory(at: home.appendingPathComponent(root), includingPropertiesForKeys: nil)) ?? []
    for file in files where ["provisionprofile", "mobileprovision"].contains(file.pathExtension) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["cms", "-D", "-i", file.path]
        let pipe = Pipe(); process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        if process.terminationStatus == 0,
           let profile = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            profiles.append(profile)
        }
    }
}
let now = Date()
let host = profiles.contains { AutoFillProvisioning.authorizes($0, bundleID: "com.scarcrux.textem", teamID: team, now: now) }
let provider = profiles.contains { AutoFillProvisioning.authorizes($0, bundleID: "com.scarcrux.textem.codeprovider", teamID: team, now: now) }
print("decoded_profiles=\(profiles.count) host_authorized=\(host) provider_authorized=\(provider)")
if !host || !provider { print("gate=matching_autofill_capability_profiles_required; no installation attempted") }
