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

    /// A code observed arriving in Textem's own Google Messages window. An
    /// empty domain means the message named no site: offer it only when the
    /// person picks it from Textem's AutoFill list, never inline for a site.
    public init?(detection: CodeDetector.Detection, accountID: UUID, receivedAt: Date, consent: Bool) {
        guard consent, detection.code.range(of: #"^[0-9]{4,8}$"#, options: .regularExpression) != nil else { return nil }
        if let domain = detection.domain, !Self.validDomain(domain) { return nil }
        id = UUID(); self.accountID = accountID; self.domain = detection.domain ?? ""
        code = detection.code; self.receivedAt = receivedAt; self.consent = consent
    }

    public var isDomainBound: Bool { !domain.isEmpty }

    public static func validDomain(_ domain: String) -> Bool {
        guard domain.utf8.count <= 253, domain == domain.lowercased() else { return false }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy {
            $0.utf8.count <= 63 && $0.range(of: #"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$"#, options: .regularExpression) != nil
        }
    }

    /// `requested` is the site asking; pass "" to ask about an any-site code.
    public func eligible(domain requested: String, now: Date) -> Bool {
        consent && !consumed && domain == requested && (domain.isEmpty || Self.validDomain(domain)) &&
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

    /// The single inline offer for a site. Any-site codes never qualify here.
    public static func select(_ samples: [CodeSample], domains: Set<String>, recordID: String? = nil,
                              now: Date) -> CodeSample? {
        let matches = samples.filter {
            $0.isDomainBound && domains.contains($0.domain) && $0.eligible(domain: $0.domain, now: now)
        }
        guard matches.count == 1, let sample = matches.first,
              recordID == nil || sample.id.uuidString == recordID else { return nil }
        return sample
    }

    /// Codes for the AutoFill list the person opens explicitly: the single
    /// unambiguous code bound to the requesting site (if any), then every fresh
    /// any-site code, newest first. The person chooses; nothing is auto-filled.
    public static func offers(_ samples: [CodeSample], domains: Set<String>, now: Date, limit: Int = 5) -> [CodeSample] {
        let bound = select(samples, domains: domains, now: now).map { [$0] } ?? []
        let open = samples.filter { !$0.isDomainBound && $0.eligible(domain: "", now: now) }
            .sorted { $0.receivedAt > $1.receivedAt }
        return Array((bound + open).prefix(limit))
    }

    /// Re-check a previously shown offer at the moment the person clicks.
    public static func revalidate(_ samples: [CodeSample], id: UUID, domains: Set<String>, now: Date) -> CodeSample? {
        offers(samples, domains: domains, now: now, limit: .max).first { $0.id == id }
    }
}
