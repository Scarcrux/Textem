import SwiftUI

/// Explicit local-library access is independent of Google's current route.
/// It never grants linking, refresh or navigation authority to a saved label.
@MainActor final class SavedPhoneConversationsModel: ObservableObject {
    struct Conversation: Identifiable {
        let id: String
        let name: String
        let savedAt: Date
        let messages: Int
        let hasHistory: Bool
    }
    let accountID: UUID
    let directory: URL
    let historyDirectory: URL
    @Published private(set) var records: [PhoneConversationStore.Record] = []
    @Published private(set) var histories: [PhoneHistoryStore.Record] = []
    @Published var selectedHistoryKey: String?
    @Published var selectedKey: String?
    @Published var showHistory = false
    @Published var showOriginalCaptures = false
    @Published private(set) var error: String?
    private var names: [String: String] = [:]
    private var unreadableNames = Set<String>()
    var selected: PhoneConversationStore.Record? { records.first { $0.conversationKey == selectedKey } }
    var selectedHistory: PhoneHistoryStore.Record? { histories.first { $0.conversationKey == selectedHistoryKey } }
    var selectionKey: String? { showHistory ? selectedHistoryKey : selectedKey }
    var selectedConversation: Conversation? { conversations.first { $0.id == selectionKey } }
    var selectedHasBoth: Bool {
        guard let key = selectionKey else { return false }
        return histories.contains { $0.conversationKey == key } && records.contains { $0.conversationKey == key }
    }
    var conversations: [Conversation] {
        let keys = Set(records.map(\.conversationKey)).union(histories.map(\.conversationKey))
        return keys.map { key in
            let history = histories.first { $0.conversationKey == key }
            let preview = records.first { $0.conversationKey == key }
            let name = names[key] ?? preview.flatMap { PhoneHistoryStore.cleanName($0.samples.last?.title ?? "") }
                ?? (unreadableNames.contains(key) ? "Name unavailable" : "Unnamed conversation")
            let milliseconds = history?.snapshot.capturedAtMS ?? preview?.samples.map(\.capturedAtMS).max() ?? 0
            let count = history?.snapshot.messages.count ?? PhonePreviewPresentation(samples: preview?.samples ?? []).messages.count
            return Conversation(id: key, name: name, savedAt: Date(timeIntervalSince1970: Double(milliseconds) / 1000), messages: count, hasHistory: history != nil)
        }.sorted { $0.savedAt == $1.savedAt ? $0.id < $1.id : $0.savedAt > $1.savedAt }
    }
    init(accountID: UUID, directory: URL = PhoneConversationStore.directory, historyDirectory: URL? = nil) {
        self.accountID = accountID; self.directory = directory
        self.historyDirectory = historyDirectory ?? (directory == PhoneConversationStore.directory ? PhoneHistoryStore.directory : directory.appendingPathComponent("SelectedHistory"))
        reload()
    }
    func selectConversation(_ key: String?) {
        guard let key, conversations.contains(where: { $0.id == key }) else { return }
        selectedKey = records.first { $0.conversationKey == key }?.conversationKey
        selectedHistoryKey = histories.first { $0.conversationKey == key }?.conversationKey
        showHistory = selectedHistoryKey != nil
        showOriginalCaptures = false
    }
    func moveSelection(_ offset: Int) {
        let rows = conversations
        guard !rows.isEmpty else { return }
        let next = rows.firstIndex(where: { $0.id == selectionKey }).map { min(rows.count - 1, max(0, $0 + offset)) } ?? 0
        selectConversation(rows[next].id)
    }
    func reload() {
        let previous = selectionKey, previousHistory = showHistory, previousOriginals = showOriginalCaptures
        do {
            let account = PhoneConversationStore.accountKey(accountID)
            let previews = try PhoneConversationStore.load(in: directory).filter { $0.accountKey == account }
            let saved = try PhoneHistoryStore.load(in: historyDirectory).filter { $0.accountKey == account }
            names = [:]; unreadableNames = []
            for record in saved {
                do { names[record.conversationKey] = try PhoneHistoryStore.displayName(for: record, in: historyDirectory) }
                catch { unreadableNames.insert(record.conversationKey) }
            }
            records = previews; histories = saved
            selectedKey = nil; selectedHistoryKey = nil
            selectConversation(conversations.contains(where: { $0.id == previous }) ? previous : conversations.first?.id)
            if previous == selectionKey {
                if selectedHasBoth { showHistory = previousHistory }
                showOriginalCaptures = previousOriginals
            }
            error = nil
        } catch {
            records = []; histories = []; names = [:]; unreadableNames = []
            selectedKey = nil; selectedHistoryKey = nil; self.error = error.localizedDescription
        }
    }
    static func label(_ record: PhoneConversationStore.Record) -> String {
        PhoneHistoryStore.cleanName(record.samples.last?.title ?? "") ?? "Unnamed conversation"
    }
}

struct SavedPhoneConversationsView: View {
    @ObservedObject var model: SavedPhoneConversationsModel
    var onClose: () -> Void
    var showHeader = true
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showHeader {
                PhonePanelHeader(symbol: "tray.full", title: "Saved conversations", subtitle: "Current account",
                    onClose: onClose, closeLabel: "Close saved conversations", trailingActions: AnyView(headerActions))
                    .padding(.horizontal, 20).padding(.vertical, 14)
                Divider()
            }
            if let error = model.error {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Saved conversations couldn’t be opened").font(.headline)
                    Text(error).textSelection(.enabled)
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if model.conversations.isEmpty {
                SavedConversationEmptyView()
            } else {
                HSplitView {
                    List {
                        ForEach(model.conversations) { conversation in
                            Button { model.selectConversation(conversation.id) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(verbatim: conversation.name).font(.headline).lineLimit(2)
                                    Text(conversation.savedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(conversation.hasHistory ? "\(conversation.messages) messages" : "\(conversation.messages) message previews")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                    .foregroundStyle(.primary)
                                    .background(model.selectionKey == conversation.id ? Color.accentColor.opacity(0.15) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityAddTraits(model.selectionKey == conversation.id ? .isSelected : [])
                                .listRowBackground(Color.clear)
                        }
                    }.listStyle(.sidebar).frame(minWidth: 160, idealWidth: 210, maxWidth: 240)
                        .onMoveCommand { direction in
                            if direction == .up { model.moveSelection(-1) }
                            if direction == .down { model.moveSelection(1) }
                        }
                        .accessibilityLabel("Saved conversations")
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if let conversation = model.selectedConversation {
                                Text(verbatim: conversation.name).font(.title2).bold()
                                if model.selectedHasBoth {
                                    Picker("Messages", selection: $model.showHistory) {
                                        Text("Saved messages").tag(true)
                                        Text("Recent previews").tag(false)
                                    }.pickerStyle(.segmented).labelsHidden()
                                }
                                if model.showHistory, let record = model.selectedHistory {
                                    PhoneHistoryView(snapshot: record.snapshot)
                                } else if let record = model.selected {
                                    Text("Saved from your phone · \(PhonePreviewPresentation(samples: record.samples).messages.count) message previews")
                                        .font(.caption).foregroundStyle(.secondary)
                                    PhonePreviewListView(samples: record.samples, showOriginalCaptures: model.showOriginalCaptures)
                                }
                            } else { Text("Select a conversation").foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }.frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private var headerActions: some View {
        HStack(spacing: 8) {
            Button { model.reload() } label: {
                Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
            }.buttonStyle(.plain).help("Reload saved conversations").accessibilityLabel("Reload saved conversations")
            if model.selected != nil && !model.showHistory {
                Menu {
                    Toggle("Show every saved preview", isOn: $model.showOriginalCaptures)
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Preview options").accessibilityLabel("Preview options")
            }
        }
    }
}

private struct SavedConversationEmptyView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("No saved conversations yet").font(.title2).bold()
            Text("This library shows phone conversations and previews already saved on this Mac. Your ordinary Google Messages inbox isn’t downloaded for offline use.")
            Text("Saving phone history currently requires Textem’s developer Android companion, installed on your phone and connected to this Mac. The companion isn’t included with the Mac app.")
                .foregroundStyle(.secondary)
            Text("Already using the companion? Go online, then enable “Show phone companion tools” in Settings → Advanced to save a conversation here.")
                .foregroundStyle(.secondary)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
