import Foundation

/// Finds a verification code in one incoming message, the way Messages offers
/// "From Messages" codes: any text that reads as a verification message and
/// contains exactly one plausible code. A message ending in Apple's
/// domain-bound footer (`@site.com #123456`) is scoped to that site.
///
/// Conservative by design: two different candidate numbers, no verification
/// wording, or digits glued to letters/separators all yield nil. Offering the
/// wrong number is worse than offering nothing.
public enum CodeDetector {
    public struct Detection: Equatable, Sendable {
        public let code: String
        /// Present only for a valid domain-bound footer; nil means "any site".
        public let domain: String?
        public init(code: String, domain: String?) { self.code = code; self.domain = domain }
    }

    public static let maximumMessageBytes = 4096

    // Whole words only: "pin" must not match "shipping".
    private static let keywords = try! NSRegularExpression(pattern:
        #"\b(codes?|verification|verify|verifying|passcode|password|otp|pin|one[- ]time|2fa|two[- ]factor|authenticat\w*|security|log ?in|sign[- ]?in|confirm\w*)\b"#,
        options: .caseInsensitive)
    // Marketing texts also say "code"; a promo code is not a sign-in code.
    private static let marketing = try! NSRegularExpression(pattern:
        #"\b(promo|coupon|discount|voucher|% off|percent off|sale|reward)\b"#, options: .caseInsensitive)

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public static func detect(_ message: String) -> Detection? {
        guard !message.isEmpty, message.utf8.count <= maximumMessageBytes else { return nil }
        if let bound = domainBound(message) { return bound }
        guard matches(keywords, message), !matches(marketing, message) else { return nil }
        // Footer-shaped text that failed domain validation is not silently
        // downgraded to an any-site code.
        if message.split(separator: "\n").contains(where: { $0.hasPrefix("@") && $0.contains(" #") }) { return nil }
        let candidates = Set(numbers(in: message))
        guard candidates.count == 1, let code = candidates.first else { return nil }
        return Detection(code: code, domain: nil)
    }

    private static func domainBound(_ message: String) -> Detection? {
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false)
        let footerPattern = #"^@[a-z0-9.-]+ #[0-9]{4,8}$"#
        guard lines.filter({ $0.range(of: footerPattern, options: .regularExpression) != nil }).count == 1,
              let footer = lines.last,
              footer.range(of: footerPattern, options: .regularExpression) != nil else { return nil }
        let fields = footer.split(separator: " ")
        let domain = String(fields[0].dropFirst()), code = String(fields[1].dropFirst())
        guard CodeSample.validDomain(domain), Set(numbers(in: message)) == [code] else { return nil }
        return Detection(code: code, domain: domain)
    }

    /// 4–8 digit runs not touching letters, digits, or number punctuation, so
    /// phone numbers (555-1234), amounts ($12.50, 1,000) and times are skipped.
    /// A short capital prefix like Google's "G-482913" is allowed and dropped.
    static func numbers(in message: String) -> [String] {
        let pattern = #"(?<![A-Za-z0-9$€£.,:/-])(?:[A-Z]{1,3}-)?([0-9]{4,8})(?![A-Za-z0-9%]|[.,:/-][0-9])"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = message as NSString
        return regex.matches(in: message, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }
}
