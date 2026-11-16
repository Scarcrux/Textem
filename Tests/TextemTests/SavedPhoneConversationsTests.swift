import Darwin
import Foundation
import Testing
@testable import scarcrux_textem

@Suite("Saved previews without a live Google route", .serialized) @MainActor
struct SavedPhoneConversationsTests {
    @Test func coldReopenIsReadOnlyAndScopedToAccountRatherThanTitle() throws {
        let root = try PhoneImageTests().temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = PhoneImageConversation(accountID: UUID(), route: "first-route", label: "Example delivery")
        let b = PhoneImageConversation(accountID: UUID(), route: "second-route", label: a.label)
        let sample = try PhoneConversationTests().fixture(picture: true)
        let other = try PhoneConversationTests().fixture(changes: ["source_key": String(repeating: "b", count: 64)])
        try PhoneConversationStore.link(sample, to: a, in: root)
        try PhoneConversationStore.link(other, to: b, in: root)
        let file = root.appendingPathComponent("previews.json"), before = try Data(contentsOf: file)
        let first = SavedPhoneConversationsModel(accountID: a.accountID, directory: root)
        #expect(first.records.count == 1 && first.selected?.samples == [sample])
        #expect(first.selected?.samples.first?.image?.data == sample.image?.data)
        let reopened = SavedPhoneConversationsModel(accountID: a.accountID, directory: root)
        #expect(reopened.selected == first.selected)
        let second = SavedPhoneConversationsModel(accountID: b.accountID, directory: root)
        #expect(second.records.count == 1 && second.selected?.samples == [other])
        second.selectedKey = first.selectedKey
        #expect(second.selected == nil)
        #expect(SavedPhoneConversationsModel(accountID: UUID(), directory: root).records.isEmpty)
        #expect(try Data(contentsOf: file) == before)
        try PhoneConversationStore.unlink(a, in: root)
        first.reload(); #expect(first.records.isEmpty && first.selected == nil)
    }
    @Test func unsafeOrMalformedReloadClearsPreviouslyDisplayedContent() throws {
        let root = try PhoneImageTests().temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = PhoneImageConversation(accountID: UUID(), route: "synthetic-route", label: "Example")
        try PhoneConversationStore.link(PhoneNotificationTests().fixture(), to: context, in: root)
        let model = SavedPhoneConversationsModel(accountID: context.accountID, directory: root)
        #expect(model.selected != nil)
        let file = root.appendingPathComponent("previews.json"), original = try Data(contentsOf: file)
        chmod(file.path, 0o644); model.reload()
        #expect(model.error != nil && model.records.isEmpty && model.selectedKey == nil)
        chmod(file.path, 0o600); model.reload(); #expect(model.selected != nil)
        try Data("{}".utf8).write(to: file); model.reload()
        #expect(model.error != nil && model.selected == nil)
        try original.write(to: file); model.reload(); #expect(model.selected != nil)
    }
}
