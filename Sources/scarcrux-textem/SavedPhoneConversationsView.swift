import SwiftUI

/// Explicit local-library access is independent of Google's current route.
/// It never grants linking, refresh or navigation authority to a saved label.
@MainActor final class SavedPhoneConversationsModel: ObservableObject {
    let accountID: UUID
    let directory: URL
    @Published private(set) var records: [PhoneConversationStore.Record] = []
    let historyDirectory: URL
    @Published private(set) var histories: [PhoneHistoryStore.Record] = []
    @Published var selectedHistoryKey: String?
    @Published var showHistory = false
    var selectedHistory: PhoneHistoryStore.Record? { histories.first { $0.conversationKey == selectedHistoryKey } }
    @Published var selectedKey: String?
    @Published var showOriginalCaptures = false
    @Published private(set) var error: String?
    var selected: PhoneConversationStore.Record? {
        records.first { $0.conversationKey == selectedKey }
    }
    init(accountID: UUID, directory: URL = PhoneConversationStore.directory, historyDirectory: URL? = nil) {
        self.accountID = accountID; self.directory = directory
        self.historyDirectory = historyDirectory ?? (directory == PhoneConversationStore.directory ? PhoneHistoryStore.directory : directory.appendingPathComponent("SelectedHistory"))
        reload(); showHistory = records.isEmpty && !histories.isEmpty
    }
    func reload() {
        do {
            records = try PhoneConversationStore.load(in: directory).filter {
                $0.accountKey == PhoneConversationStore.accountKey(accountID)
            }
            if !records.contains(where: { $0.conversationKey == selectedKey }) {
                selectedKey = records.first?.conversationKey
            }
            histories = try PhoneHistoryStore.load(in: historyDirectory).filter { $0.accountKey == PhoneConversationStore.accountKey(accountID) }
            if !histories.contains(where: { $0.conversationKey == selectedHistoryKey }) { selectedHistoryKey = histories.first?.conversationKey }
            error = nil
        } catch {
            records = []; selectedKey = nil; histories = []; selectedHistoryKey = nil; self.error = error.localizedDescription
        }
    }
    static func label(_ record: PhoneConversationStore.Record) -> String {
        let title = record.samples.last?.title ?? ""
        return title.isEmpty ? "Saved conversation" : title
    }
}

struct SavedPhoneConversationsView: View {
    @ObservedObject var model: SavedPhoneConversationsModel
    var onClose: () -> Void
    var showHeader = true
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showHeader { PhonePanelHeader(symbol: "tray.full", title: "Saved conversation previews",
                subtitle: "On this Mac · current account", onClose: onClose,
                closeLabel: "Close saved conversation previews", trailingActions: AnyView(headerActions))
                .padding(.horizontal, 20).padding(.vertical, 14)
            Divider() }

            VStack(alignment: .leading, spacing: 8) {
                Text("Saved on this Mac and available offline.")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.histories.isEmpty {
                    Toggle("Show selected phone history", isOn: $model.showHistory)
                }
                if model.showHistory && !model.histories.isEmpty {
                    Picker("Selected history", selection: $model.selectedHistoryKey) {
                        ForEach(Array(model.histories.enumerated()), id: \.element.conversationKey) { index, record in
                            Text("Saved history \(index + 1) · \(record.snapshot.messages.count) rows").tag(Optional(record.conversationKey))
                        }
                    }
                } else if !model.records.isEmpty {
                    Picker("Conversation", selection: $model.selectedKey) {
                        ForEach(model.records, id: \.conversationKey) { record in
                            Text(verbatim: SavedPhoneConversationsModel.label(record)).tag(Optional(record.conversationKey))
                        }
                    }
                }
            }.padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = model.error {
                        Text("Saved previews couldn’t be opened").font(.headline)
                        Text(error).textSelection(.enabled)
                    } else if model.showHistory, let record = model.selectedHistory {
                        PhoneHistoryView(snapshot: record.snapshot)
                    } else if let record = model.selected {
                        PhonePreviewListView(samples: record.samples, showOriginalCaptures: model.showOriginalCaptures)
                    } else {
                        Text("No saved previews for this account").font(.headline)
                        Text("When the phone is connected, open a phone-only conversation and explicitly link its captured source. Saved previews will then be available here offline.")
                            .foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private var headerActions: some View {
        HStack(spacing: 8) {
            Button { model.reload() } label: {
                Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
            }.buttonStyle(.plain).help("Reload saved previews").accessibilityLabel("Reload saved previews")
            if model.selected != nil {
                Menu {
                    Toggle("Show original captures", isOn: $model.showOriginalCaptures)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 28, height: 28)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Preview options").accessibilityLabel("Preview options")
            }
        }
    }
}
