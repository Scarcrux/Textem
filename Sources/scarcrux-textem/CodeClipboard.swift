import AppKit

// Puts a verification code on the clipboard marked as concealed and transient,
// the convention clipboard managers honour to avoid recording secrets.
@MainActor
enum CodeClipboard {
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func copy(_ code: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, concealed, transient], owner: nil)
        pasteboard.setString(code, forType: .string)
        pasteboard.setString(code, forType: concealed)
        pasteboard.setData(Data(), forType: transient)
    }
}


// Only observed incoming messages can supply the system-wide shortcut.
// Use elapsed time so changing the wall clock can't refresh a stale PIN.
struct RecentVerificationCode {
    let code: String
    let receivedAt: ContinuousClock.Instant

    func freshValue(at now: ContinuousClock.Instant) -> String? {
        let elapsed = receivedAt.duration(to: now)
        return elapsed >= .zero && elapsed < .seconds(180) ? code : nil
    }
}
