import SwiftUI

/// Explicit local-library access is independent of Google's current route.
/// It never grants linking, refresh or navigation authority to a saved label.
@MainActor final class SavedPhoneConversationsModel: ObservableObject {
    let accountID: UUID
    let directory: URL
    @Published private(set) var records: [PhoneConversationStore.Record] = []
    @Published var selectedKey: String?
    @Published private(set) var error: String?
    var selected: PhoneConversationStore.Record? {
        records.first { $0.conversationKey == selectedKey }
    }
    init(accountID: UUID, directory: URL = PhoneConversationStore.directory) {
        self.accountID = accountID; self.directory = directory; reload()
    }
    func reload() {
        do {
            records = try PhoneConversationStore.load(in: directory).filter {
                $0.accountKey == PhoneConversationStore.accountKey(accountID)
            }
            if !records.contains(where: { $0.conversationKey == selectedKey }) {
                selectedKey = records.first?.conversationKey
            }
            error = nil
        } catch {
            records = []; selectedKey = nil; self.error = error.localizedDescription
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
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PhonePanelHeader(symbol: "tray.full", title: "Saved conversation previews",
                subtitle: "On this Mac · current account", onClose: onClose,
                closeLabel: "Close saved conversation previews").padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Available without the phone or Google’s conversation screen. These are partial captured previews; full history is not established.")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.records.isEmpty {
                    Picker("Conversation", selection: $model.selectedKey) {
                        ForEach(model.records, id: \.conversationKey) { record in
                            Text(verbatim: SavedPhoneConversationsModel.label(record)).tag(Optional(record.conversationKey))
                        }
                    }
                }
                Button("Reload saved previews") { model.reload() }
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = model.error {
                        Text("Saved previews couldn’t be opened").font(.headline)
                        Text(error).textSelection(.enabled)
                    } else if let record = model.selected {
                        ForEach(Array(record.samples.enumerated()), id: \.offset) { _, sample in
                            PhoneConversationSampleView(sample: sample)
                        }
                    } else {
                        Text("No saved previews for this account").font(.headline)
                        Text("When the phone is connected, open a phone-only conversation and explicitly link its captured source. Saved previews will then be available here offline.")
                            .foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}
