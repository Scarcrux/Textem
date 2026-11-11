import AppKit
import AuthenticationServices
import NativeAutoFillCore

private final class ProviderBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

/// Real public AutoFill entry point. Not embedded in the shipping app until
/// signing, encrypted shared storage and live message-ingestion gates pass.
@available(macOS 15.0, *)
@objc(TextemCodeProvider)
public final class CredentialProvider: ASCredentialProviderViewController {
    // Missing entitlement, locked device, disabled consent or malformed storage
    // all fail closed. Tests replace this reader with in-memory synthetic data.
    public var readSamples: () -> [CodeSample] = {
        (try? CodeVault(storage: KeychainCodeStorage()).eligible(now: Date())) ?? []
    }
    public var now: () -> Date = Date.init
    public var testCompletion: ((String?) -> Void)?
    public var testCancellation: ((ASExtensionError.Code) -> Void)?
    private var offered: CodeSample?
    private var domains: Set<String> = []
    private var selectedRecordID: String?

    public override func loadView() {
        view = ProviderBackground(frame: NSRect(x: 0, y: 0, width: 460, height: 240))
        show(nil)
    }

    public override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        selectedRecordID = nil
        domains = Self.domains(serviceIdentifiers)
        refresh()
    }

    public override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        // Always get explicit confirmation in this first prototype. Never return
        // the newest code merely because the OS asks for any credential type.
        guard credentialRequest.type == .oneTimeCode else { cancel(.credentialIdentityNotFound); return }
        cancel(.userInteractionRequired)
    }

    public override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        guard credentialRequest.type == .oneTimeCode,
              let identity = credentialRequest.credentialIdentity as? ASOneTimeCodeCredentialIdentity,
              let recordID = identity.recordIdentifier else { cancel(.credentialIdentityNotFound); return }
        selectedRecordID = recordID
        domains = Self.domains([identity.serviceIdentifier])
        refresh()
    }

    public override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        cancel(.credentialIdentityNotFound) // No passwords or passkeys supplied.
    }

    private static func domains(_ identifiers: [ASCredentialServiceIdentifier]) -> Set<String> {
        Set(identifiers.compactMap { CodePolicy.domain(for: $0.identifier, isURL: $0.type == .URL) })
    }

    private func refresh() {
        _ = view // Ensure the native view exists before presentation.
        offered = CodePolicy.select(readSamples(), domains: domains, recordID: selectedRecordID, now: now())
        show(offered)
    }

    private func show(_ sample: CodeSample?) {
        view.subviews.forEach { $0.removeFromSuperview() }
        let title = NSTextField(labelWithString: "Textem verification code")
        title.font = .boldSystemFont(ofSize: 18)
        let detail = NSTextField(wrappingLabelWithString: sample.map {
            "Use the recently received code for \($0.domain)."
        } ?? "No single fresh, domain-matched code is available. Textem will not guess or reuse an expired code.")
        let use = NSButton(title: "Fill Code", target: self, action: #selector(fillCode))
        use.bezelStyle = .rounded
        use.identifier = NSUserInterfaceItemIdentifier("fill-code")
        use.isEnabled = sample != nil
        let close = NSButton(title: "Cancel", target: self, action: #selector(cancelSelection))
        close.bezelStyle = .rounded
        let stack = NSStackView(views: [title, detail, use, close])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24)
        ])
    }

    @objc public func fillCode() {
        // Re-read on click: a once-visible option is not a continuing grant.
        guard let offered,
              let current = CodePolicy.select(readSamples(), domains: domains, recordID: offered.id.uuidString, now: now()),
              current == offered else { self.offered = nil; show(nil); return }
        self.offered = nil
        show(nil)
        if let testCompletion { testCompletion(current.code); return }
        extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: current.code))
    }

    @objc public func cancelSelection() {
        offered = nil
        if let testCompletion { testCompletion(nil); return }
        cancel(.userCanceled)
    }

    private func cancel(_ code: ASExtensionError.Code) {
        offered = nil; domains = []; selectedRecordID = nil
        if isViewLoaded { show(nil) }
        if let testCancellation { testCancellation(code); return }
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: code.rawValue))
    }
}
