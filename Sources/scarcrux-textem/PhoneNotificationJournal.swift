import Foundation

struct PhoneNotificationJournal: Sendable {
    let samples: [PhoneNotificationSnapshot]
    let dropped: Int
    static let maximumBytes = 8 * 1024 * 1024
    static func parse(_ data: Data, now: Date = Date()) throws -> Self {
        let object = try PhoneNotificationJSON.object(data, maximum: maximumBytes)
        guard Set(object.keys) == ["schema", "kind", "epoch", "revision", "dropped", "samples", "complete", "written_at_ms"],
              ["schema", "revision", "dropped", "written_at_ms"].allSatisfy({ PhoneNotificationJSON.integer(object[$0]) }),
              object["schema"] as? Int == 1, object["kind"] as? String == "NOTIFICATION_JOURNAL",
              let complete = object["complete"] as? NSNumber, CFGetTypeID(complete) == CFBooleanGetTypeID(), !complete.boolValue,
              let epoch = object["epoch"] as? String, UUID(uuidString: epoch)?.uuidString.lowercased() == epoch,
              let revision = object["revision"] as? Int, (1...Int(Int32.max)).contains(revision),
              let dropped = object["dropped"] as? Int, (0...Int(Int32.max)).contains(dropped),
              let written = object["written_at_ms"] as? Int64,
              Double(written) <= now.timeIntervalSince1970 * 1000 + 300_000,
              Double(written) >= now.timeIntervalSince1970 * 1000 - 1_800_000,
              let rows = object["samples"] as? [[String: Any]], (1...32).contains(rows.count) else { throw PhoneNotificationError.invalid }
        let samples = try rows.map { try PhoneNotificationSnapshot.parse(JSONSerialization.data(withJSONObject: $0), now: now, requireFresh: false) }
        guard Set(samples.map(\.installID)).count == 1,
              samples.allSatisfy({ $0.capturedAtMS <= written && $0.capturedAtMS >= written - 7 * 86_400_000 }),
              Dictionary(grouping: samples, by: \.sourceKey).values.allSatisfy({ $0.count <= 4 }) else { throw PhoneNotificationError.invalid }
        return Self(samples: samples, dropped: dropped)
    }
}
