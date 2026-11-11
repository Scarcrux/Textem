import Foundation

/// Metadata only; codes and original SMS text never go into the suggestion index.
public struct CodeIndexEntry: Equatable, Sendable {
    public let recordID: String
    public let domain: String
    public let label: String
    public static func project(_ samples: [CodeSample], now: Date) -> [Self] {
        let eligible = samples.filter { $0.eligible(domain: $0.domain, now: now) }
        let groups = Dictionary(grouping: eligible, by: \.domain)
        return groups.keys.sorted().compactMap { domain in
            guard let rows = groups[domain], rows.count == 1, let sample = rows.first else { return nil }
            return Self(recordID: sample.id.uuidString, domain: domain, label: "Textem verification code")
        }
    }
}
