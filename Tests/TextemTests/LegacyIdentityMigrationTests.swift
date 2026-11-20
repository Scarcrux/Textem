import Foundation
import Testing
@testable import scarcrux_textem

@Suite("Carry-over from the original bundle identifier")
struct LegacyIdentityMigrationTests {
    private func sandbox() throws -> (library: URL, defaults: UserDefaults, suite: String) {
        let library = FileManager.default.temporaryDirectory.appendingPathComponent("textem-migrate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let suite = "dev.textem.migration-tests.\(UUID().uuidString)"
        return (library, UserDefaults(suiteName: suite)!, suite)
    }
    private let old = LegacyIdentityMigration.legacyIdentifier, new = LegacyIdentityMigration.currentIdentifier

    @Test func copiesSessionsCookiesAndSettingsOnceWithoutTouchingTheOriginals() throws {
        let (library, defaults, suite) = try sandbox()
        defer { try? FileManager.default.removeItem(at: library); defaults.removePersistentDomain(forName: suite) }
        let store = library.appendingPathComponent("WebKit/\(old)/WebsiteData/Default")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try Data("session".utf8).write(to: store.appendingPathComponent("cookies.db"))
        try FileManager.default.createDirectory(at: library.appendingPathComponent("HTTPStorages"), withIntermediateDirectories: true)
        try Data("jar".utf8).write(to: library.appendingPathComponent("HTTPStorages/\(old).binarycookies"))
        defaults.set(true, forKey: "hideAvatars")   // already chosen in the new app: must win

        let report = LegacyIdentityMigration.runIfNeeded(library: library, bundleIdentifier: new, defaults: defaults,
            legacyPreferences: { ["blurMessages": true, "hideAvatars": false, "zoom": 1.2] })
        #expect(report.preferences == 2)
        #expect(MigrationFollowUp.shouldPresent(in: defaults))
        #expect(defaults.bool(forKey: "blurMessages") && defaults.bool(forKey: "hideAvatars") && defaults.double(forKey: "zoom") == 1.2)
        #expect(report.copied == ["WebKit/\(old)", "HTTPStorages/\(old).binarycookies"])
        let copied = library.appendingPathComponent("WebKit/\(new)/WebsiteData/Default/cookies.db")
        #expect(try Data(contentsOf: copied) == Data("session".utf8))
        #expect(FileManager.default.fileExists(atPath: store.appendingPathComponent("cookies.db").path), "original kept")

        // Second launch: nothing happens again, even if old data changes.
        let again = LegacyIdentityMigration.runIfNeeded(library: library, bundleIdentifier: new, defaults: defaults,
            legacyPreferences: { ["blurMessages": false] })
        #expect(again.skipped && defaults.bool(forKey: "blurMessages"))
        #expect(MigrationFollowUp.shouldPresent(in: defaults), "An unopened app window may leave the sheet pending")
        MigrationFollowUp.markOffered(in: defaults)
        let relaunched = try #require(UserDefaults(suiteName: suite))
        #expect(!MigrationFollowUp.shouldPresent(in: relaunched))
        #expect(MigrationFollowUp.isAvailable(in: relaunched), "Help remains available after the first offer")
    }

    @Test func emptyMigrationDoesNotOfferFollowUp() throws {
        let (library, defaults, suite) = try sandbox()
        defer { try? FileManager.default.removeItem(at: library); defaults.removePersistentDomain(forName: suite) }
        let report = LegacyIdentityMigration.runIfNeeded(library: library, bundleIdentifier: new, defaults: defaults,
                                                         legacyPreferences: { [:] })
        #expect(report.preferences == 0 && report.copied.isEmpty)
        #expect(defaults.bool(forKey: LegacyIdentityMigration.doneKey))
        #expect(!MigrationFollowUp.shouldPresent(in: defaults))
        #expect(!MigrationFollowUp.isAvailable(in: defaults))
    }

    @Test func neverOverwritesNewDataAndNeverRunsUnderTheOldIdentifier() throws {
        let (library, defaults, suite) = try sandbox()
        defer { try? FileManager.default.removeItem(at: library); defaults.removePersistentDomain(forName: suite) }
        for id in [old, new] {
            let dir = library.appendingPathComponent("WebKit/\(id)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(id.utf8).write(to: dir.appendingPathComponent("marker"))
        }
        let report = LegacyIdentityMigration.runIfNeeded(library: library, bundleIdentifier: new, defaults: defaults,
                                                          legacyPreferences: { [:] })
        #expect(report.copied.isEmpty)
        #expect(try Data(contentsOf: library.appendingPathComponent("WebKit/\(new)/marker")) == Data(new.utf8))
        let (_, other, otherSuite) = try sandbox()
        defer { other.removePersistentDomain(forName: otherSuite) }
        #expect(LegacyIdentityMigration.runIfNeeded(library: library, bundleIdentifier: old, defaults: other,
                                                    legacyPreferences: { ["x": 1] }).skipped)
    }
}
