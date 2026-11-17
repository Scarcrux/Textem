import Foundation

enum PhoneHistoryError: String, Error, LocalizedError {
    case invalid = "The selected phone history has an invalid format or source."
    case notPublished = "On your phone, choose a history thread and tap Make this history available to paired Mac. Then try again."
    var errorDescription: String? { rawValue }
}

/// Public-provider text explicitly published on the phone; never a notification or a complete RCS archive.
struct PhoneHistorySnapshot: Codable, Equatable, Sendable {
    struct Message: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let timestampMS: Int64
        let text: String
        let direction: String
        let truncated: Bool
        let attachmentsOmitted: Int
        let partsComplete: Bool
        enum CodingKeys: String, CodingKey {
            case id, text, direction, truncated
            case timestampMS = "timestamp_ms", attachmentsOmitted = "attachments_omitted", partsComplete = "parts_complete"
        }
    }
    let schema: Int
    let kind: String
    let installID: String
    let sourceKey: String
    let capturedAtMS: Int64
    let complete: Bool
    let sms: String
    let mms: String
    let limited: Bool
    let messages: [Message]
    enum CodingKeys: String, CodingKey {
        case schema, kind, complete, sms, mms, limited, messages
        case installID = "install_id", sourceKey = "source_key", capturedAtMS = "captured_at_ms"
    }
    static let maximumBytes = 2 * 1024 * 1024
    var bindingKey: String { PhoneImageManifest.digest(Data((installID + ":" + sourceKey).utf8)) }
    private static func hex(_ value: String) -> Bool { value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }
    private static func boolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
    static func parse(_ data: Data, now: Date = Date(), requireFresh: Bool = true) throws -> Self {
        let object = try PhoneNotificationJSON.object(data, maximum: maximumBytes)
        guard Set(object.keys) == ["schema", "kind", "install_id", "source_key", "captured_at_ms", "complete", "sms", "mms", "limited", "messages"],
              PhoneNotificationJSON.integer(object["schema"]), PhoneNotificationJSON.integer(object["captured_at_ms"]),
              boolean(object["complete"]), boolean(object["limited"]),
              let rows = object["messages"] as? [[String: Any]], rows.count <= 1000,
              rows.allSatisfy({ row in
                  Set(row.keys) == ["id", "timestamp_ms", "text", "direction", "truncated", "attachments_omitted", "parts_complete"]
                  && PhoneNotificationJSON.integer(row["timestamp_ms"]) && PhoneNotificationJSON.integer(row["attachments_omitted"])
                  && boolean(row["truncated"]) && boolean(row["parts_complete"])
              }),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.schema == 1, value.kind == "SELECTED_PHONE_HISTORY", !value.complete,
              UUID(uuidString: value.installID)?.uuidString.lowercased() == value.installID, hex(value.sourceKey),
              [value.sms, value.mms].allSatisfy({ ["OK", "BLOCKED", "UNAVAILABLE", "ERROR"].contains($0) }),
              value.capturedAtMS > 0, Double(value.capturedAtMS) <= now.timeIntervalSince1970 * 1000 + 300_000,
              !requireFresh || Double(value.capturedAtMS) >= now.timeIntervalSince1970 * 1000 - 7 * 86_400_000,
              Set(value.messages.map(\.id)).count == value.messages.count,
              value.messages.allSatisfy({ row in
                  hex(row.id) && row.timestampMS >= 0 && row.timestampMS <= value.capturedAtMS + 300_000
                  && row.text.utf16.count <= 20_000 && ["RECEIVED", "SENT", "OTHER"].contains(row.direction)
                  && (0...32).contains(row.attachmentsOmitted)
              }), zip(value.messages, value.messages.dropFirst()).allSatisfy({ $0.timestampMS <= $1.timestampMS }) else {
            throw PhoneHistoryError.invalid
        }
        return value
    }
    static func library(_ data: Data, installID: String, now: Date = Date()) throws -> [Self] {
        let object = try PhoneNotificationJSON.object(data, maximum: PhoneNotificationJournal.maximumBytes)
        guard Set(object.keys) == ["schema", "kind", "samples"], PhoneNotificationJSON.integer(object["schema"]),
              object["schema"] as? Int == 1, object["kind"] as? String == "PHONE_HISTORY_LIBRARY",
              let rows = object["samples"] as? [[String: Any]], rows.count <= 8 else { throw PhoneHistoryError.invalid }
        let samples = try rows.map { try parse(JSONSerialization.data(withJSONObject: $0), now: now, requireFresh: false) }
        guard samples.allSatisfy({ $0.installID == installID }), Set(samples.map(\.sourceKey)).count == samples.count else { throw PhoneHistoryError.invalid }
        return samples.filter { Double($0.capturedAtMS) >= now.timeIntervalSince1970 * 1000 - 7 * 86_400_000 }
    }
}

struct CompanionHistoryTransport: Sendable {
    var load: @Sendable () throws -> Data? = { try CompanionCredentialStore().load() }
    var network: @Sendable (CompanionPairing) async throws -> [PhoneHistorySnapshot] = { pairing in
        try await CompanionPairedClient<[PhoneHistorySnapshot]>(network: { candidate in
            let (data, response, id) = try await CompanionHTTPSJournalClient().fetchData(pairing: candidate,
                path: "/v1/selected-history", maximum: PhoneNotificationJournal.maximumBytes)
            return try Self.validateReply(data, response: response, requestID: id, pairing: candidate)
        }).fetch(pairing: pairing)
    }
    static func validateReply(_ data: Data, response: HTTPURLResponse, requestID: UUID, pairing: CompanionPairing) throws -> [PhoneHistorySnapshot] {
        guard response.statusCode == 200, response.mimeType == "application/json",
              response.value(forHTTPHeaderField: "X-Textem-Request-ID") == requestID.uuidString.lowercased() else {
            throw CompanionConnectionError.invalidReply
        }
        return try PhoneHistorySnapshot.library(data, installID: pairing.installID)
    }
    func fetch() async throws -> [PhoneHistorySnapshot] {
        try OfflineMode.requireOnline()
        guard let saved = try load(), !saved.isEmpty else { throw CompanionConnectionError.disconnected }
        let result = try await network(CompanionPairing.parse(saved))
        try Task.checkCancellation()
        guard try load() == saved else { throw CompanionConnectionError.disconnected }
        guard !result.isEmpty else { throw PhoneHistoryError.notPublished }
        return result
    }
}
