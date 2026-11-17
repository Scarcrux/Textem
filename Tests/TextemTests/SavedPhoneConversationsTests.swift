import Darwin
import Foundation
import Testing
@testable import scarcrux_textem

@Suite("Saved previews without a live Google route", .serialized) @MainActor
struct SavedPhoneConversationsTests {
    @Test func namedHistoryAndPreviewsShareOneConversationWithoutChangingIdentity() throws {
        let root = try PhoneImageTests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let context = PhoneHistoryTests().context
        let history = root.appendingPathComponent("history")
        let sample = try PhoneHistoryTests().fixture()
        try PhoneConversationStore.link(PhoneNotificationTests().fixture(), to: context, in: root)
        #expect(try PhoneHistoryStore.link(sample, to: context, in: history))
        let model = SavedPhoneConversationsModel(accountID: context.accountID, directory: root, historyDirectory: history)
        #expect(model.conversations.count == 1)
        let entry = try #require(model.conversations.first)
        #expect(entry.name == context.label && entry.id == context.key && entry.messages == 3)
        #expect(entry.savedAt == Date(timeIntervalSince1970: Double(sample.capturedAtMS) / 1000))
        #expect(model.selectedHasBoth && model.showHistory)
        let before = try Data(contentsOf: history.appendingPathComponent("history.json"))
        model.showHistory = false; model.reload()
        #expect(!model.showHistory && model.selected != nil)
        #expect(try Data(contentsOf: history.appendingPathComponent("history.json")) == before)
    }
    @Test func legacyHistoryGetsOnlyItsExactlyAssociatedPreviewName() throws {
        let root = try PhoneImageTests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let context = PhoneHistoryTests().context, history = root.appendingPathComponent("history")
        try PhoneHistoryStore.link(PhoneHistoryTests().fixture(), to: context, in: history)
        let key = try #require(context.key)
        try FileManager.default.removeItem(at: history.appendingPathComponent(key + ".name.json"))
        let unrelated = PhoneImageConversation(accountID: context.accountID, route: "unrelated-route", label: "Unrelated contact")
        let wrong = try PhoneConversationTests().fixture(changes: ["title": "Wrong conversation"])
        try PhoneConversationStore.link(wrong, to: unrelated, in: root)
        let model = SavedPhoneConversationsModel(accountID: context.accountID, directory: root, historyDirectory: history)
        #expect(model.conversations.first { $0.id == key }?.name == "Unnamed conversation")
        let match = try PhoneConversationTests().fixture(changes: ["title": "Matched contact", "source_key": String(repeating: "b", count: 64)])
        try PhoneConversationStore.link(match, to: context, in: root)
        model.reload()
        #expect(model.conversations.first { $0.id == key }?.name == "Matched contact")
        let stranger = SavedPhoneConversationsModel(accountID: UUID(), directory: root, historyDirectory: history)
        #expect(stranger.conversations.isEmpty)
    }
    @Test func equalNamesNeverMergeDistinctConversationKeys() throws {
        let root = try PhoneImageTests().temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let first = PhoneHistoryTests().context
        let second = PhoneImageConversation(accountID: first.accountID, route: "another-history-route", label: first.label)
        let a = try PhoneHistoryTests().fixture()
        let b = try PhoneHistoryTests().fixture(["source_key": String(repeating: "b", count: 64), "captured_at_ms": a.capturedAtMS - 60_000])
        try PhoneHistoryStore.link(a, to: first, in: root)
        try PhoneHistoryStore.link(b, to: second, in: root)
        let model = SavedPhoneConversationsModel(accountID: first.accountID, directory: root.appendingPathComponent("previews"), historyDirectory: root)
        #expect(model.conversations.count == 2 && Set(model.conversations.map(\.id)).count == 2)
        #expect(Set(model.conversations.map(\.name)) == [first.label])
        #expect(model.conversations.first?.id == first.key)
        model.selectConversation(second.key)
        #expect(model.selectedHistory?.snapshot == b && model.selectedKey == nil)
        model.moveSelection(-1)
        #expect(model.selectedHistory?.snapshot == a)
        model.moveSelection(-1)
        #expect(model.selectedHistory?.snapshot == a)
        model.moveSelection(1)
        #expect(model.selectedHistory?.snapshot == b)
    }
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
