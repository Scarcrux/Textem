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
}
