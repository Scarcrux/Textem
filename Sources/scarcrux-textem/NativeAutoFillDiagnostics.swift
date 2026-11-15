import Foundation

/// Operational API evidence only, never a UI/DOM/state-text snapshot. In
/// particular, no raw error, code, domain, sender, account or shortcut identifier.
@MainActor enum NativeAutoFillDiagnostics {
    enum Event: String { case ready, providerDisabled, vaultRefused, publicationRefused, runtimeUnavailable }
    struct Counts: Equatable {
        var capture = 0
        var provider = 0
        var sources = 0
        var eligible = 0
        var indexed = 0
        var withheld = 0
        var failure = 0
    }
    static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Textem/native-autofill.jsonl")
    static func record(_ event: Event, _ counts: Counts) {
        try? append(event, counts, to: url)
    }
    static func append(_ event: Event, _ counts: Counts, to url: URL) throws {
        try NotificationDiagnostics.append(event.rawValue, values: [
            "capture": counts.capture == 0 ? 0 : 1, "provider": counts.provider == 0 ? 0 : 1,
            "sources": min(16, max(0, counts.sources)), "eligible": min(16, max(0, counts.eligible)),
            "indexed": min(16, max(0, counts.indexed)), "withheld": min(16, max(0, counts.withheld)),
            "failure": min(Int(Int32.max), max(Int(Int32.min), counts.failure)),
            "process": Int(ProcessInfo.processInfo.processIdentifier)
        ], to: url)
    }
}
