import Foundation
import NativeAutoFillCore

// Verification codes in conversation rows that just changed in the inbox.
// Outgoing previews ("You: …") are the person's own text, never a received code.
struct ReceivedCodes {
    private(set) var rows: [(conversation: String, row: ConversationSnapshot)] = []
    private var detected: [String: CodeDetector.Detection] = [:]

    static let outgoingPrefixes = ["You:"]

    static func detect(in changed: [ConversationSnapshot]) -> ReceivedCodes {
        var result = ReceivedCodes()
        for row in changed where !outgoingPrefixes.contains(where: { row.snippet.hasPrefix($0) }) {
            guard let detection = CodeDetector.detect(row.snippet) else { continue }
            result.rows.append((row.id, row))
            result.detected[row.id] = detection
        }
        return result
    }

    func code(for conversation: String) -> String? { detected[conversation]?.code }

    /// What one inbox update should do with received codes. Pure, so tests can
    /// drive it from the real bridge without the app's notification centre.
    struct Plan {
        var store: [(conversation: String, message: String)] = []
        var messageNotifications: [(event: ConversationSnapshot, code: String?)] = []
        var codeNotifications: [(code: String, row: ConversationSnapshot)] = []
    }

    /// `notify` is false while Textem is frontmost or muted (the existing
    /// notification rule); storing for AutoFill does not depend on it.
    static func plan(events: [ConversationSnapshot], changed: [ConversationSnapshot],
                     notify: Bool, offerCopy: Bool) -> Plan {
        let codes = detect(in: changed)
        var plan = Plan()
        plan.store = codes.rows.map { ($0.conversation, $0.row.snippet) }
        guard notify else { return plan }
        plan.messageNotifications = events.map { ($0, offerCopy ? codes.code(for: $0.id) : nil) }
        if offerCopy {
            for (conversation, row) in codes.rows where !events.contains(where: { $0.id == conversation }) {
                if let code = codes.code(for: conversation) { plan.codeNotifications.append((code, row)) }
            }
        }
        return plan
    }
}
