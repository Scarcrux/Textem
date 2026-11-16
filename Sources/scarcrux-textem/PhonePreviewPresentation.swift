import Foundation

/// A display projection, never a replacement for the retained observations.
struct PhonePreviewPresentation {
    struct Row: Identifiable {
        let id: Int
        let message: PhoneNotificationSnapshot.Message
        let capturedAtMS: Int64
    }
    private struct Identity: Hashable {
        let install: String
        let source: String
        let time: Int64
        let text: String
        let truncated: Bool
    }
    let messages: [Row]
    let pictureCaptures: [PhoneNotificationSnapshot]
    let hasMissingPictures: Bool
    let originalMessageCount: Int
    init(samples: [PhoneNotificationSnapshot]) {
        let captures = samples.enumerated().sorted {
            $0.element.capturedAtMS == $1.element.capturedAtMS
                ? $0.offset < $1.offset : $0.element.capturedAtMS < $1.element.capturedAtMS
        }.map(\.element)
        var rows: [Row] = []
        var seen: [Identity: Int] = [:]
        var originalCount = 0
        for sample in captures {
            var occurrences: [Identity: Int] = [:]
            for message in sample.messages where !message.text.isEmpty {
                originalCount += 1
                let key = Identity(install: sample.installID, source: sample.sourceKey,
                    time: message.timestampMS, text: message.text, truncated: message.truncated)
                occurrences[key, default: 0] += 1
                // No supplied time means no reliable overlap identity. Keep it.
                // Multiplicity is counted per observation, not collapsed to a set.
                if message.timestampMS > 0, occurrences[key, default: 0] <= seen[key, default: 0] { continue }
                rows.append(Row(id: rows.count, message: message, capturedAtMS: sample.capturedAtMS))
            }
            seen.merge(occurrences, uniquingKeysWith: max)
        }
        messages = rows; originalMessageCount = originalCount
        // Notification-level pictures cannot safely be assigned to message rows.
        pictureCaptures = captures.filter { $0.image != nil }
        hasMissingPictures = captures.contains { $0.uriAttachments > 0 || ["UNSUPPORTED", "UNAVAILABLE"].contains($0.imageState) }
    }
}
