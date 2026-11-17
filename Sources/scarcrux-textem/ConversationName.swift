import Foundation

// Normalizes a conversation's display name so a dismissed phone-only pane is
// remembered for that conversation regardless of spacing, case or punctuation.
enum ConversationName {
    static func normalized(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }
}
