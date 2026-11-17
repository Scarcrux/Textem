import AppKit
import AuthenticationServices
import NativeAutoFillCore
import OSLog

private final class ProviderBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

/// Public AutoFill entry point. Invocation and target fill need independent
/// live evidence; fixture controller completion does not establish either.
@available(macOS 15.0, *)
@objc(TextemCodeProvider)
public final class CredentialProvider: ASCredentialProviderViewController {
    public enum Event: String, Sendable {
        case listRequested, noninteractiveRequested, selectedRequested, otherRequested
        case vaultRefused, evaluatedOffer, fillRefused, fillRequested, systemCompletion, cancelled
    }
    private static let logger = Logger(subsystem: "com.scarcrux.textem.codes", category: "provider")
    private static func record(_ event: Event, _ value: Int) {
        guard Bundle.main.bundleIdentifier == "com.scarcrux.textem.codeprovider" else { return }
        let bounded = min(Int(Int32.max), max(Int(Int32.min), value))
        logger.notice("event=\(event.rawValue, privacy: .public) value=\(bounded, privacy: .public)")
    }
    public var observe: (Event, Int) -> Void = { CredentialProvider.record($0, $1) }
    // Missing entitlement, locked device, disabled consent or malformed storage
    // all fail closed. Tests replace this reader with in-memory synthetic data.
    public var readSamples: () -> [CodeSample] = {
        do { return try CodeVault(storage: KeychainCodeStorage()).eligible(now: Date()) }
        catch {
            let value: Int
            if case CodeVaultError.unavailable(let status) = error { value = Int(status) } else { value = 0 }
            CredentialProvider.record(.vaultRefused, value); return []
        }
    }
    public var now: () -> Date = Date.init
    public var testCompletion: ((String?) -> Void)?
    public var testCancellation: ((ASExtensionError.Code) -> Void)?
    private var offered: CodeSample?
    /// Everything shown in the list; `offered` is the default (first) choice.
    private var choices: [CodeSample] = []
    private var domains: Set<String> = []
    private var selectedRecordID: String?

    public override func loadView() {
        view = ProviderBackground(frame: NSRect(x: 0, y: 0, width: 460, height: 360))
        show(nil)
    }

    public override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        observe(.listRequested, min(16, serviceIdentifiers.count))
        selectedRecordID = nil
        domains = Self.domains(serviceIdentifiers)
        refresh()
    }

    public override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        observe(.noninteractiveRequested, Int(credentialRequest.type.rawValue))
        // Always get explicit confirmation in this first prototype. Never return
        // the newest code merely because the OS asks for any credential type.
        guard credentialRequest.type == .oneTimeCode else { cancel(.credentialIdentityNotFound); return }
        cancel(.userInteractionRequired)
    }

    public override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        observe(.selectedRequested, Int(credentialRequest.type.rawValue))
        guard credentialRequest.type == .oneTimeCode,
              let identity = credentialRequest.credentialIdentity as? ASOneTimeCodeCredentialIdentity,
              let recordID = identity.recordIdentifier else { cancel(.credentialIdentityNotFound); return }
        selectedRecordID = recordID
        domains = Self.domains([identity.serviceIdentifier])
        refresh()
    }

    public override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        observe(.otherRequested, min(16, serviceIdentifiers.count))
        cancel(.credentialIdentityNotFound) // No passwords or passkeys supplied.
    }

    private static func domains(_ identifiers: [ASCredentialServiceIdentifier]) -> Set<String> {
        Set(identifiers.compactMap { CodePolicy.domain(for: $0.identifier, isURL: $0.type == .URL) })
    }

    private func refresh() {
        _ = view // Ensure the native view exists before presentation.
        let samples = readSamples()
        if selectedRecordID != nil {
            // The OS picked one site-bound identity inline: only that record.
            offered = CodePolicy.select(samples, domains: domains, recordID: selectedRecordID, now: now())
            choices = offered.map { [$0] } ?? []
        } else {
            choices = CodePolicy.offers(samples, domains: domains, now: now())
            offered = choices.first
        }
        observe(.evaluatedOffer, choices.count)
        show(offered)
    }

    private func describe(_ sample: CodeSample) -> String {
        let seconds = max(0, Int(now().timeIntervalSince(sample.receivedAt)))
        let age = seconds < 60 ? "just now" : "\(seconds / 60) min ago"
        return sample.isDomainBound ? "For \(sample.domain) · received \(age)" : "From a text message · received \(age)"
    }

    private func show(_ sample: CodeSample?) {
        view.subviews.forEach { $0.removeFromSuperview() }
        let title = NSTextField(labelWithString: "Textem verification code")
        title.font = .boldSystemFont(ofSize: 18)
        let detail = NSTextField(wrappingLabelWithString: sample == nil
            ? "No fresh code from your texts in the last 3 minutes. Textem will not reuse an expired code."
            : "Codes that arrived in Textem in the last 3 minutes. Choose the one this site sent.")
        let use = NSButton(title: sample.map { "Fill \($0.code)" } ?? "Fill Code", target: self, action: #selector(fillCode))
        use.bezelStyle = .rounded
        use.keyEquivalent = "\r"
        use.identifier = NSUserInterfaceItemIdentifier("fill-code")
        use.isEnabled = sample != nil
        use.toolTip = sample.map(describe)
        // Each choice: its button, then where/when it came from underneath.
        var rows: [NSView] = [title, detail, use]
        var captions: [NSView] = []
        if let sample { let label = caption(describe(sample)); rows.append(label); captions.append(label) }
        for (index, other) in choices.dropFirst().enumerated() {
            let button = NSButton(title: "Fill \(other.code)", target: self, action: #selector(fillChoice(_:)))
            button.bezelStyle = .rounded
            button.tag = index + 1
            button.identifier = NSUserInterfaceItemIdentifier("fill-code-\(index + 1)")
            let label = caption(describe(other))
            rows.append(button); rows.append(label); captions.append(label)
        }
        let close = NSButton(title: "Cancel", target: self, action: #selector(cancelSelection))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        rows.append(close)
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        for label in captions {
            if let index = stack.arrangedSubviews.firstIndex(of: label), index > 0 {
                stack.setCustomSpacing(4, after: stack.arrangedSubviews[index - 1])
            }
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24)
        ])
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }

    @objc private func fillChoice(_ sender: NSButton) {
        guard choices.indices.contains(sender.tag) else { return }
        offered = choices[sender.tag]
        fillCode()
    }

    @objc public func fillCode() {
        // Re-read on click: a once-visible option is not a continuing grant.
        let samples = readSamples()
        let current: CodeSample? = offered.flatMap { offered in
            selectedRecordID != nil
                ? CodePolicy.select(samples, domains: domains, recordID: offered.id.uuidString, now: now())
                : CodePolicy.revalidate(samples, id: offered.id, domains: domains, now: now())
        }
        guard let offered, let current, current == offered else {
            observe(.fillRefused, 0); self.offered = nil; choices = []; show(nil); return
        }
        self.offered = nil; choices = []
        show(nil)
        if let testCompletion { testCompletion(current.code); return }
        observe(.fillRequested, 1)
        extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: current.code)) { [weak self] expired in
            Task { @MainActor in self?.observe(.systemCompletion, expired ? 1 : 0) }
        }
    }

    @objc public func cancelSelection() {
        offered = nil; choices = []
        if let testCompletion { testCompletion(nil); return }
        cancel(.userCanceled)
    }

    private func cancel(_ code: ASExtensionError.Code) {
        observe(.cancelled, code.rawValue)
        offered = nil; choices = []; domains = []; selectedRecordID = nil
        if isViewLoaded { show(nil) }
        if let testCancellation { testCancellation(code); return }
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: code.rawValue))
    }
}
