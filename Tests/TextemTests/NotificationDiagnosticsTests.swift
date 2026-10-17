import XCTest
@testable import scarcrux_textem

@MainActor
final class NotificationDiagnosticsTests: XCTestCase {
    func testPersistsPrivateMetadataWithoutStderr() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notifications.jsonl")
        try NotificationDiagnostics.append("snapshot", values: ["rows": 25], to: url)
        let data = try Data(contentsOf: url)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(record["event"] as? String, "snapshot")
        XCTAssertEqual(record["rows"] as? Int, 25)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRejectsSymlinkAndLeavesTargetUntouched() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        try Data("original".utf8).write(to: target)
        let link = directory.appendingPathComponent("notifications.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try NotificationDiagnostics.append("test", values: [:], to: link))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")
    }
}
