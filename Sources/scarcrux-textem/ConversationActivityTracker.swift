import Foundation

struct ConversationSnapshot: Equatable {
    let id: String
    let sender: String
    let snippet: String
    let fingerprint: String
    let isUnread: Bool
}

// Turns complete DOM snapshots into message-like changes. Tracking a count is
// insufficient: a second message in an already-unread thread does not increase
// the number of unread conversations and used to produce no notification.
struct ConversationActivityTracker {
    private struct State {
        let fingerprint: String
    }

    private var previous: [String: State]?

    mutating func update(_ rows: [ConversationSnapshot]) -> [ConversationSnapshot] {
        var current: [String: State] = [:]
        var uniqueRows: [ConversationSnapshot] = []
        var seen: Set<String> = []
        for row in rows {
            current[row.id] = State(fingerprint: row.fingerprint)
            if seen.insert(row.id).inserted { uniqueRows.append(row) }
        }
        defer { previous = current }

        // The first DOM report establishes a baseline. Existing unread threads
        // are not newly received messages and must not notify at app launch.
        guard let previous, !previous.isEmpty else { return [] }

        return uniqueRows.filter { row in
            guard row.isUnread else { return false }
            guard let old = previous[row.id] else { return true }
            // Marking an existing message unread changes state but not content.
            return row.fingerprint != old.fingerprint
        }
    }
}
