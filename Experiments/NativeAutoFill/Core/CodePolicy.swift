import Foundation

/// No production message ingestion yet: callers must establish actual arrival,
/// account identity, and opt-in before constructing a sample. Never rescan old
/// DOM snippets and assign them a new receipt time.
public struct CodeSample: Codable, Equatable, Sendable {
    public let id: UUID
    public let accountID: UUID
    public let domain: String
    public let code: String
    public let receivedAt: Date
    public let consent: Bool
    public var consumed: Bool = false

    public init?(message: String, accountID: UUID, receivedAt: Date, consent: Bool) {
        guard consent, message.utf8.count <= 4096 else { return nil }
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false)
        let footerPattern = #"^@[a-z0-9.-]+ #[0-9]{4,8}$"#
        guard lines.filter({ $0.range(of: footerPattern, options: .regularExpression) != nil }).count == 1 else { return nil }
        guard let footer = lines.last,
              let match = footer.range(of: footerPattern, options: .regularExpression),
              match == footer.startIndex..<footer.endIndex else { return nil }
        let fields = footer.split(separator: " ")
        let domain = String(fields[0].dropFirst())
        let code = String(fields[1].dropFirst())
        guard Self.validDomain(domain) else { return nil }
        // Conservative prototype: conflicting numeric codes must not be guessed.
        let re = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9])[0-9]{4,8}(?![A-Za-z0-9])"#)
        let ns = message as NSString
        let codes = Set(re.matches(in: message, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) })
        guard codes == [code] else { return nil }
        id = UUID(); self.accountID = accountID; self.domain = domain
        self.code = code; self.receivedAt = receivedAt; self.consent = consent
    }

    public static func validDomain(_ domain: String) -> Bool {
        guard domain.utf8.count <= 253, domain == domain.lowercased() else { return false }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy {
            $0.utf8.count <= 63 && $0.range(of: #"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$"#, options: .regularExpression) != nil
        }
    }

    public func eligible(domain requested: String, now: Date) -> Bool {
        consent && !consumed && Self.validDomain(domain) && domain == requested &&
        code.range(of: #"^[0-9]{4,8}$"#, options: .regularExpression) != nil &&
        now.timeIntervalSince(receivedAt) >= 0 && now.timeIntervalSince(receivedAt) < 180
    }
}

public enum CodePolicy {
    /// Do not take a suffix, display name, URL query, or best-effort route match.
    public static func domain(for service: String, isURL: Bool) -> String? {
        if !isURL { return CodeSample.validDomain(service) ? service : nil }
        guard let url = URLComponents(string: service), url.scheme == "https",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host, CodeSample.validDomain(host) else { return nil }
        return host
    }

    public static func select(_ samples: [CodeSample], domains: Set<String>, recordID: String? = nil,
                              now: Date) -> CodeSample? {
        let matches = samples.filter {
            domains.contains($0.domain) && $0.eligible(domain: $0.domain, now: now) &&
            (recordID == nil || $0.id.uuidString == recordID)
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
