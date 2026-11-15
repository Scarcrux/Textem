import AppKit
import AuthenticationServices
import Foundation
import Testing
import NativeAutoFillCore
import NativeAutoFillProvider

@Suite("Native AutoFill prototype")
struct NativeAutoFillTests {
    let time = Date(timeIntervalSince1970: 1_000_000)
    let account = UUID()
    func sample(_ text: String = "Your verification code is 004321.\n@example.com #004321") -> CodeSample? {
        CodeSample(message: text, accountID: account, receivedAt: time, consent: true)
    }

    @Test func domainBoundExtractionRejectsOrdinaryAndAmbiguousNumbers() throws {
        #expect(try #require(sample()).code == "004321")
        for text in ["Order 004321 is ready", "Code 004321", "Code 998877\n@example.com #004321",
                     "@example.com #004321\n@other.example #004321", "@example.com.evil/ #004321",
                     "@-example.com #004321", "@example..com #004321", "@example.com #004321\n"] {
            #expect(sample(text) == nil)
        }
        #expect(CodeSample(message: "@example.com #004321", accountID: account, receivedAt: time, consent: false) == nil)
    }

    @Test func exactServiceAndFreshnessControls() throws {
        var value = try #require(sample())
        #expect(value.eligible(domain: "example.com", now: time))
        for domain in ["evil.example.com", "example.com.evil", "Example.com", "other.example"] {
            #expect(!value.eligible(domain: domain, now: time))
        }
        #expect(!value.eligible(domain: "example.com", now: time.addingTimeInterval(-1)))
        #expect(!value.eligible(domain: "example.com", now: time.addingTimeInterval(180)))
        #expect(value.eligible(domain: "example.com", now: time.addingTimeInterval(179)))
        #expect(CodePolicy.select([value], domains: ["example.com"], recordID: UUID().uuidString, now: time) == nil)
        #expect(CodePolicy.select([value, value], domains: ["example.com"], now: time) == nil)
        value.consumed = true
        #expect(CodePolicy.select([value], domains: ["example.com"], now: time) == nil)
    }

    @Test func serviceURLIsNotBestEffortDomainGuess() {
        #expect(CodePolicy.domain(for: "https://example.com/login", isURL: true) == "example.com")
        for url in ["http://example.com", "https://user@example.com", "https://example.com:444", "javascript:example.com"] {
            #expect(CodePolicy.domain(for: url, isURL: true) == nil)
        }
        #expect(CodePolicy.domain(for: "https://example.com", isURL: false) == nil)
    }

    @Test func explicitRecordCannotBypassDomainAmbiguity() throws {
        let first = try #require(sample())
        let second = try #require(sample("@example.com #112233"))
        #expect(CodePolicy.select([first, second], domains: ["example.com"], recordID: first.id.uuidString, now: time) == nil)
    }

    @Test func signingGateDiscriminatesUnrelatedExpiredAndMissingCapabilities() {
        let entitlements: [String: Any] = ["com.apple.application-identifier": "TESTTEAM.com.scarcrux.textem.codeprovider",
            "keychain-access-groups": ["TESTTEAM.com.scarcrux.textem.codes"],
            "com.apple.developer.authentication-services.autofill-credential-provider": true]
        var profile: [String: Any] = ["TeamIdentifier": ["TESTTEAM"], "ExpirationDate": time.addingTimeInterval(1), "Entitlements": entitlements]
        func allowed(_ p: [String: Any], _ bundle: String = "com.scarcrux.textem.codeprovider") -> Bool {
            AutoFillProvisioning.authorizes(p, bundleID: bundle, teamID: "TESTTEAM", now: time)
        }
        #expect(allowed(profile))
        #expect(!allowed(profile, "com.scarcrux.textem"))
        profile["TeamIdentifier"] = ["OTHERTEAM"]; #expect(!allowed(profile))
        profile["TeamIdentifier"] = ["TESTTEAM"]
        profile["ExpirationDate"] = time; #expect(!allowed(profile))
        profile["ExpirationDate"] = time.addingTimeInterval(1)
        profile["Entitlements"] = ["com.apple.application-identifier": "TESTTEAM.*"]
        #expect(!allowed(profile))
    }

    @Test @MainActor func actualProviderControllerRevalidatesOnSelection() throws {
        guard #available(macOS 15, *) else { return }
        _ = NSApplication.shared
        let controller = CredentialProvider()
        var samples = [try #require(sample())]
        var clock = time
        var completed: [String?] = []
        controller.readSamples = { samples }; controller.now = { clock }
        controller.testCompletion = { completed.append($0) }
        let services = [ASCredentialServiceIdentifier(identifier: "example.com", type: .domain)]
        controller.prepareOneTimeCodeCredentialList(for: services)
        let view = controller.view
        view.appearance = NSAppearance(named: .aqua)
        view.layoutSubtreeIfNeeded()
        if let path = ProcessInfo.processInfo.environment["TEXTEM_AUTOFILL_FIXTURE"] {
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
        let stack = try #require(view.subviews.first as? NSStackView)
        let fill = try #require(stack.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "fill-code" })
        #expect(fill.isEnabled)
        fill.performClick(nil); #expect(completed == ["004321"])
        controller.fillCode(); #expect(completed.count == 1)
        controller.prepareOneTimeCodeCredentialList(for: services)
        clock = time.addingTimeInterval(180)
        controller.fillCode(); #expect(completed.count == 1)
        clock = time
        controller.prepareOneTimeCodeCredentialList(for: services)
        samples.removeAll() // Revoked/cleared after presentation.
        controller.fillCode(); #expect(completed.count == 1)
        controller.cancelSelection(); #expect(completed.count == 2 && completed[1] == nil)
    }

    @Test @MainActor func actualSystemRequestTypesAndRecordIdentity() throws {
        guard #available(macOS 15, *) else { return }
        let controller = CredentialProvider()
        let value = try #require(sample())
        controller.readSamples = { [value] }; controller.now = { time }
        var errors: [ASExtensionError.Code] = []
        var completed: [String] = []
        controller.testCancellation = { errors.append($0) }
        controller.testCompletion = { if let code = $0 { completed.append(code) } }
        func request(_ domain: String, _ record: String) -> ASOneTimeCodeCredentialRequest {
            ASOneTimeCodeCredentialRequest(credentialIdentity: ASOneTimeCodeCredentialIdentity(
                serviceIdentifier: ASCredentialServiceIdentifier(identifier: domain, type: .domain),
                label: "Synthetic Textem code", recordIdentifier: record))
        }
        let correct = request("example.com", value.id.uuidString)
        controller.provideCredentialWithoutUserInteraction(for: correct)
        #expect(errors == [.userInteractionRequired])
        controller.prepareInterfaceToProvideCredential(for: request("other.example", value.id.uuidString))
        controller.fillCode(); #expect(completed.isEmpty)
        controller.prepareInterfaceToProvideCredential(for: request("example.com", UUID().uuidString))
        controller.fillCode(); #expect(completed.isEmpty)
        controller.prepareInterfaceToProvideCredential(for: correct)
        controller.fillCode(); #expect(completed == ["004321"])
        controller.prepareInterfaceToProvideCredential(for: correct)
        controller.prepareCredentialList(for: []) // A password-list request invalidates the offer.
        controller.fillCode(); #expect(completed.count == 1)
        #expect(errors.last == .credentialIdentityNotFound)
    }
    @Test @MainActor func providerRequestObservationCannotConfuseMockCompletionWithSystemFill() throws {
        guard #available(macOS 15, *) else { return }
        let controller = CredentialProvider()
        let value = try #require(sample())
        var clock = time
        var events: [(CredentialProvider.Event, Int)] = []
        controller.readSamples = { [value] }; controller.now = { clock }
        controller.observe = { events.append(($0, $1)) }
        controller.testCompletion = { _ in }
        controller.testCancellation = { _ in }
        let services = [ASCredentialServiceIdentifier(identifier: "example.com", type: .domain)]
        controller.prepareOneTimeCodeCredentialList(for: services)
        #expect(events.contains { $0.0 == .listRequested && $0.1 == 1 })
        #expect(events.contains { $0.0 == .evaluatedOffer && $0.1 == 1 })
        controller.fillCode()
        #expect(!events.contains { $0.0 == .systemCompletion || $0.0 == .fillRequested })
        controller.prepareOneTimeCodeCredentialList(for: services)
        clock = time.addingTimeInterval(180); controller.fillCode()
        #expect(events.last?.0 == .fillRefused)
        controller.prepareCredentialList(for: services)
        #expect(events.contains { $0.0 == .otherRequested })
    }
}
