import Foundation
import Testing
@testable import scarcrux_textem

@Suite("Conservative phone preview presentation", .serialized) @MainActor
struct PhonePreviewPresentationTests {
    typealias Message = PhoneNotificationSnapshot.Message
    func sample(_ messages: [Message], offset: Int64 = 0, source: String? = nil,
                install: String? = nil, picture: Bool = false) throws -> PhoneNotificationSnapshot {
        let base = try PhoneNotificationTests().fixture(picture: picture)
        let value = PhoneNotificationSnapshot(schema: base.schema, kind: base.kind,
            capturedAtMS: base.capturedAtMS + offset, origin: base.origin,
            installID: install ?? base.installID, sourceKey: source ?? base.sourceKey,
            title: base.title, messages: messages, truncated: base.truncated,
            image: base.image, imageState: base.imageState, uriAttachments: base.uriAttachments, complete: false)
        return try PhoneNotificationSnapshot.parse(JSONEncoder().encode(value))
    }
    func overlapSamples() throws -> [PhoneNotificationSnapshot] {
        let time = Int64(Date().timeIntervalSince1970 * 1000)
        let a = Message(timestampMS: time - 120_000, text: "The first example preview.", truncated: false)
        let b = Message(timestampMS: time - 60_000, text: "The second example preview. https://example.invalid/details", truncated: false)
        let c = Message(timestampMS: time - 10_000, text: "One new preview in the later capture.", truncated: false)
        return try [sample([a, b], offset: -1000), sample([a, b, c])]
    }
    @Test func overlappingWindowsCoalesceOnlyForDisplayAndLeaveStoredBytesUntouched() throws {
        let samples = try overlapSamples()
        let root = try PhoneImageTests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let context = PhoneImageConversation(accountID: UUID(), route: "synthetic-route", label: "Example")
        try PhoneConversationStore.link(samples[0], to: context, in: root)
        try PhoneConversationStore.ingest(samples[1], for: context, in: root)
        let file = root.appendingPathComponent("previews.json"), bytes = try Data(contentsOf: file)
        let stored = try #require(try PhoneConversationStore.record(for: context, in: root))
        let presentation = PhonePreviewPresentation(samples: stored.samples)
        #expect(presentation.originalMessageCount == 5 && presentation.messages.count == 3)
        #expect(presentation.messages.map(\.message) == samples[1].messages)
        #expect(try PhoneConversationStore.record(for: context, in: root)?.samples == samples)
        #expect(try Data(contentsOf: file) == bytes)
    }
    @Test func sameTextAtDifferentTimesAndUnknownTimesRemainSeparate() throws {
        let a = Message(timestampMS: 1000, text: "Repeated legitimate message", truncated: false)
        let b = Message(timestampMS: 2000, text: a.text, truncated: false)
        let unknown = Message(timestampMS: 0, text: a.text, truncated: false)
        let value = PhonePreviewPresentation(samples: try [sample([a, unknown], offset: -1000), sample([a, b, unknown])])
        #expect(value.messages.map(\.message) == [a, unknown, b, unknown])
    }
    @Test func repeatedOccurrencesWithinOneCapturePreserveMaximumMultiplicity() throws {
        let a = Message(timestampMS: 1000, text: "Identical but separately observed", truncated: false)
        let value = PhonePreviewPresentation(samples: try [sample([a, a], offset: -1000), sample([a]), sample([a, a, a], offset: 1000)])
        #expect(value.originalMessageCount == 6 && value.messages.count == 3)
    }
    @Test func sourceInstallationEditsAndTruncationNeverMergeByTitleOrTextAlone() throws {
        let a = Message(timestampMS: 1000, text: "Example preview", truncated: false)
        let edit = Message(timestampMS: 1000, text: "Changed example preview", truncated: false)
        let truncated = Message(timestampMS: 1000, text: a.text, truncated: true)
        let values = try [sample([a]), sample([a], source: String(repeating: "b", count: 64)),
            sample([a], install: "fd862212-0a6a-4772-aa92-b20df73e4932"), sample([edit, truncated])]
        #expect(PhonePreviewPresentation(samples: values).messages.count == 5)
    }
    @Test func pictureObservationsArePreservedWithoutAssigningThemToMessages() throws {
        let a = Message(timestampMS: 1000, text: "Example with picture", truncated: false)
        let values = try [sample([a], offset: -1000, picture: true), sample([a], picture: true)]
        let presentation = PhonePreviewPresentation(samples: values)
        #expect(presentation.messages.count == 1 && presentation.pictureCaptures == values)
        let pictureOnly = try sample([], picture: true)
        let only = PhonePreviewPresentation(samples: [pictureOnly])
        #expect(only.messages.isEmpty && only.pictureCaptures == [pictureOnly])
    }
}
