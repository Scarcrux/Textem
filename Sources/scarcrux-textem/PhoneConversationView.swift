import AppKit
import SwiftUI

@MainActor final class PhoneConversationModel: ObservableObject {
    let context: PhoneImageConversation
    let directory: URL
    let imageDirectory: URL
    @Published private(set) var pictures: [ImportedPhoneImage] = []
    @Published private(set) var pictureError: String?
    @Published private(set) var record: PhoneConversationStore.Record?
    @Published private(set) var candidate: PhoneNotificationSnapshot?
    @Published private(set) var candidates: [PhoneNotificationSnapshot] = []
    @Published private(set) var history: PhoneHistoryStore.Record?
    @Published private(set) var historyCandidates: [PhoneHistorySnapshot] = []
    @Published var historyCandidateKey: String?
    @Published var showHistory = false
    var historyCandidate: PhoneHistorySnapshot? { historyCandidates.first { $0.bindingKey == historyCandidateKey } }
    let historyDirectory: URL
    private let fetchHistory: @Sendable () async throws -> [PhoneHistorySnapshot]
    @Published private(set) var busy = false
    private(set) var lastSuccessfulRefresh: Date?
    private(set) var lastRefreshTransport: PhoneJournalTransport = .unknown
    @Published var automatic = true
    @Published var showOriginalCaptures = false
    @Published var status = "Google did not provide this conversation to the web client. Link a captured phone preview to recover supported content here."
    var validate: @MainActor (PhoneImageConversation) async -> Bool = { _ in false }
    private let fetch: @Sendable (String) async throws -> PhoneNotificationJournal
    private let endpoint: @MainActor () -> String
    private var generation = UUID()
    private var stopped = false
    init(context: PhoneImageConversation, directory: URL = PhoneConversationStore.directory,
         endpoint: @escaping @MainActor () -> String = { UserDefaults.standard.string(forKey: "phoneImageEndpoint") ?? "" },
         fetch: @escaping @Sendable (String) async throws -> PhoneNotificationJournal = { try await CompanionJournalTransport().fetch(developerEndpoint: $0) },
         historyDirectory: URL? = nil, imageDirectory: URL? = nil,
         fetchHistory: @escaping @Sendable () async throws -> [PhoneHistorySnapshot] = { try await CompanionHistoryTransport().fetch() }) {
        self.context = context; self.directory = directory; self.endpoint = endpoint; self.fetch = fetch
        self.historyDirectory = historyDirectory ?? (directory == PhoneConversationStore.directory ? PhoneHistoryStore.directory : directory.appendingPathComponent("SelectedHistory"))
        self.fetchHistory = fetchHistory
        self.imageDirectory = imageDirectory ?? (directory == PhoneConversationStore.directory
            ? PhoneImageStore.directory : directory.appendingPathComponent("PhoneImages"))
        reload()
        showHistory = history != nil
        if hasSavedContent { status = "" }
    }
    var hasSavedContent: Bool { record != nil || history != nil || !pictures.isEmpty }

    func reload() {
        reloadPictures()
        do {
            record = try PhoneConversationStore.record(for: context, in: directory)
            history = try PhoneHistoryStore.record(for: context, in: historyDirectory)
        }
        catch { record = nil; history = nil; status = error.localizedDescription }
    }
    private func reloadPictures() {
        do {
            pictures = try PhoneImageStore.images(for: context, in: imageDirectory)
            pictureError = nil
        } catch {
            pictures = []
            pictureError = error.localizedDescription
        }
    }

    func changePicture(_ picture: ImportedPhoneImage, removeMacCopy: Bool) async {
        guard !stopped, !busy, pictures.contains(picture) else { return }
        let id = UUID()
        generation = id
        busy = true
        defer { if generation == id { busy = false } }
        guard await validate(context), generation == id, !Task.isCancelled else { return }
        do {
            guard try PhoneImageStore.images(for: context, in: imageDirectory).contains(picture) else {
                reloadPictures()
                return
            }
            if removeMacCopy { try PhoneImageStore.remove(picture, in: imageDirectory) }
            else { try PhoneImageStore.unlink(picture, in: imageDirectory) }
            reloadPictures()
        } catch { pictureError = error.localizedDescription }
    }

    func cancel() { stopped = true; generation = UUID(); busy = false; candidate = nil; candidates = []; historyCandidates = []; historyCandidateKey = nil }
    func connectionChanged() {
        generation = UUID(); busy = false; candidate = nil; candidates = []; historyCandidates = []; historyCandidateKey = nil
        lastSuccessfulRefresh = nil; lastRefreshTransport = .unknown
        status = "Phone connection changed. Saved previews are retained; refresh to check the connection."
    }
    func chooseSource(_ key: String) { guard !busy else { return }; candidate = candidates.first { PhoneConversationStore.sourceKey($0) == key } }
    func read() async {
        guard !stopped, !busy else { return }
        let id = UUID(); generation = id; busy = true
        defer { if generation == id { busy = false } }
        do {
            guard await validate(context), generation == id, !Task.isCancelled else { return }
            let journal = try await fetch(endpoint())
            guard generation == id, !Task.isCancelled, await validate(context), generation == id, !Task.isCancelled else { return }
            if let record {
                let matching = journal.samples.filter { record.sourceKey == PhoneConversationStore.sourceKey($0) }
                guard !matching.isEmpty else {
                    status = "The phone journal contains another source. Saved previews remain available; nothing was assigned here."; return
                }
                for sample in matching { try PhoneConversationStore.ingest(sample, for: context, in: directory) }; reload()
                lastSuccessfulRefresh = Date(); lastRefreshTransport = journal.transport
                status = "Phone previews updated."
                if journal.dropped > 0 { status += " The bounded phone journal has discarded \(journal.dropped) older capture(s)." }
            } else {
                let latest = journal.samples.sorted { $0.capturedAtMS > $1.capturedAtMS }
                var seen = Set<String>()
                candidates = latest.filter { seen.insert(PhoneConversationStore.sourceKey($0)).inserted }
                candidate = candidates.first
                status = "Check the phone source and preview below. Link only if they belong to this conversation."
            }
        } catch {
            guard generation == id, !Task.isCancelled else { return }
            status = "Couldn’t refresh phone previews. Saved content is retained. " + error.localizedDescription
        }
    }
    func link() async {
        guard !stopped, !busy, let sample = candidate else { return }
        let id = UUID(); generation = id; busy = true
        defer { if generation == id { busy = false } }
        guard await validate(context), generation == id, !Task.isCancelled, candidate == sample else { return }
        do {
            try PhoneConversationStore.link(sample, to: context, in: directory)
            candidate = nil; candidates = []; reload()
            status = "Phone source linked to this account and conversation. Captured previews refresh while this pane is open."
        } catch { status = error.localizedDescription }
    }
    func unlink() {
        generation = UUID(); busy = false; candidate = nil; candidates = []; historyCandidates = []; historyCandidateKey = nil
        lastSuccessfulRefresh = nil; lastRefreshTransport = .unknown
        do {
            try PhoneConversationStore.unlink(context, in: directory); reload()
            status = "Source unlinked and this conversation’s cached previews deleted. Phone originals and shared images are unchanged."
        } catch { status = error.localizedDescription }
    }
    func dismissPreviewSelection() { candidate = nil; candidates = []; status = "" }
    func dismissHistorySelection() { historyCandidates = []; historyCandidateKey = nil }
    func readHistory() async {
        guard !stopped, !busy else { return }
        let id = UUID(); generation = id; busy = true
        defer { if generation == id { busy = false } }
        do {
            guard await validate(context), generation == id, !Task.isCancelled else { return }
            let samples = try await fetchHistory()
            guard generation == id, !Task.isCancelled, await validate(context), generation == id, !Task.isCancelled else { return }
            // A known history binding can refresh only from its exact installation/source.
            if let history {
                guard let sample = samples.first(where: { $0.bindingKey == history.sourceKey }) else {
                    status = "The phone has no published snapshot for this linked history. Saved history is retained."; return
                }
                let named = try PhoneHistoryStore.link(sample, to: context, in: historyDirectory); reload(); showHistory = true
                status = named ? "Saved messages updated. Save the conversation again on your phone to get newer messages."
                    : "Messages saved, but the conversation name couldn’t be saved."
            } else {
                historyCandidates = samples.sorted { $0.capturedAtMS > $1.capturedAtMS }
                historyCandidateKey = historyCandidates.first?.bindingKey
                candidate = nil; candidates = []
                status = "Check that these messages belong to this conversation before saving them."
            }
        } catch {
            guard generation == id, !Task.isCancelled else { return }
            status = "Couldn’t read saved messages from your phone. Your saved messages are still available. " + error.localizedDescription
        }
    }
    func linkHistory() async {
        guard !stopped, !busy, let sample = historyCandidate else { return }
        let id = UUID(); generation = id; busy = true
        defer { if generation == id { busy = false } }
        guard await validate(context), generation == id, !Task.isCancelled, historyCandidate == sample else { return }
        do {
            let named = try PhoneHistoryStore.link(sample, to: context, in: historyDirectory)
            historyCandidates = []; historyCandidateKey = nil; reload(); showHistory = true
            status = named ? "Messages saved for this conversation. You can read them in Offline Mode."
                : "Messages saved, but the conversation name couldn’t be saved."
        } catch { status = error.localizedDescription }
    }
    func unlinkHistory() {
        generation = UUID(); busy = false; historyCandidates = []; historyCandidateKey = nil
        do {
            try PhoneHistoryStore.unlink(context, in: historyDirectory); reload(); showHistory = false
            status = "Saved messages removed from this Mac."
        } catch { status = error.localizedDescription }
    }
    func run() async {
        while !stopped && !Task.isCancelled {
            if record != nil && automatic && !showHistory && historyCandidates.isEmpty { await read() }
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
        }
    }
}

struct PhoneConversationView: View {
    @ObservedObject var model: PhoneConversationModel
    var onClose: () -> Void
    var onImages: () -> Void
    @State private var connection: CompanionConnectionModel?
    @State private var pictureToRemove: ImportedPhoneImage?
    private var confirmingSource: Bool { model.historyCandidate != nil || model.candidate != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PhonePanelHeader(symbol: "iphone", title: model.context.label,
                subtitle: model.hasSavedContent ? "Saved from your phone" : "Phone conversation",
                onClose: onClose, closeLabel: "Close saved conversation",
                trailingActions: AnyView(headerActions)).padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            if !model.status.isEmpty || model.busy || model.pictureError != nil {
                HStack(alignment: .top, spacing: 8) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.pictureError ?? model.status).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 8)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let selected = model.historyCandidate {
                        Text("Confirm conversation").font(.headline)
                        Picker("From your phone", selection: $model.historyCandidateKey) {
                            ForEach(Array(model.historyCandidates.enumerated()), id: \.element.bindingKey) { _, sample in
                                Text("\(sample.messages.count) messages · \(Date(timeIntervalSince1970: Double(sample.capturedAtMS) / 1000).formatted())").tag(Optional(sample.bindingKey))
                            }
                        }.disabled(model.busy)
                        Button("Save messages to this conversation") { Task { await model.linkHistory() } }.disabled(model.busy)
                        Button("Cancel") { model.dismissHistorySelection() }.disabled(model.busy)
                        PhoneHistoryView(snapshot: selected)
                    } else if let candidate = model.candidate {
                        Text("Confirm phone source").font(.headline)
                        Picker("Captured phone source", selection: Binding(get: { PhoneConversationStore.sourceKey(candidate) }, set: { model.chooseSource($0) })) {
                            ForEach(model.candidates, id: \.sourceKey) { sample in
                                Text(verbatim: sample.title.isEmpty ? "Unnamed phone source" : sample.title).tag(PhoneConversationStore.sourceKey(sample))
                            }
                        }.disabled(model.busy)
                        Text(verbatim: candidate.title.isEmpty ? "Unnamed phone source" : candidate.title).font(.subheadline)
                        PhoneConversationSampleView(sample: candidate)
                        Button("This belongs here — link and refresh previews") { Task { await model.link() } }.disabled(model.busy)
                        Button("Cancel") { model.dismissPreviewSelection() }.disabled(model.busy)
                    } else if model.hasSavedContent {
                        savedTimeline
                    } else {
                        Text("No phone source linked").font(.headline)
                        Text("Read a phone preview, check its source and content, then explicitly link it here. Textem will not guess from a sender name.")
                            .foregroundStyle(.secondary)
                        Button("Read phone preview") { Task { await model.read() } }.disabled(model.busy)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
        }.background(Color(nsColor: .windowBackgroundColor))
            .sheet(isPresented: Binding(get: { connection != nil }, set: { if !$0 { connection = nil } })) {
                if let connection { CompanionConnectionView(model: connection, onChanged: model.connectionChanged, onClose: { self.connection = nil }) }
            }
            .confirmationDialog("Remove this picture from your Mac?", isPresented: Binding(
                get: { pictureToRemove != nil }, set: { if !$0 { pictureToRemove = nil } }
            ), presenting: pictureToRemove) { picture in
                Button("Remove Mac copy", role: .destructive) {
                    Task { await model.changePicture(picture, removeMacCopy: true) }
                }
            } message: { _ in
                Text("The picture on your phone will stay there.")
            }
            .task { await model.run() }.onDisappear { model.cancel() }
    }

    @ViewBuilder private var savedTimeline: some View {
        let history = model.showHistory || model.record == nil ? model.history?.snapshot : nil
        let samples = model.record?.samples ?? []
        let originals = history == nil && model.showOriginalCaptures
        let timeline = SavedPhoneTimeline(history: history, samples: samples, pictures: model.pictures,
                                          showOriginalCaptures: originals)
        if originals { PhonePreviewListView(samples: samples, showOriginalCaptures: true) }
        ForEach(Array(timeline.items.enumerated()), id: \.element.id) { index, item in
            if let date = item.date,
               index == 0 || timeline.items[index - 1].date.map({ !Calendar.current.isDate($0, inSameDayAs: date) }) != false {
                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)
            }
            switch item {
            case .history(let message):
                PhoneHistoryMessageView(row: message, inTimeline: true)
            case .preview(let row):
                PhonePreviewMessageView(message: row.message, capturedAtMS: row.capturedAtMS, inTimeline: true)
            case .capturedPicture(let sample, _):
                if let data = sample.image?.data, let image = NSImage(data: data) {
                    SavedPhonePictureBubble(image: image, caption: "Captured \(formatted(item.date, timeOnly: true))")
                }
            case .importedPicture(let picture):
                if let data = try? PhoneImageStore.imageData(picture, in: model.imageDirectory),
                   let image = NSImage(data: data) {
                    SavedPhonePictureBubble(image: image, caption: "Saved \(formatted(item.date, timeOnly: true))")
                } else {
                    Text("Saved picture unavailable").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if history != nil || !samples.isEmpty {
            Text("Some messages or pictures may be missing.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func formatted(_ date: Date?, timeOnly: Bool = false) -> String {
        date?.formatted(date: timeOnly ? .omitted : .abbreviated, time: .shortened) ?? "Time unavailable"
    }

    private var headerActions: some View {
        Menu {
            if model.record != nil || model.history != nil {
                Button("Refresh saved conversation") {
                    Task { if model.showHistory { await model.readHistory() } else { await model.read() } }
                }
            }
            if model.history != nil && model.record != nil {
                Toggle("Show saved messages", isOn: $model.showHistory)
            }
            if model.record == nil && model.hasSavedContent {
                Button("Read phone preview…") { Task { await model.read() } }
            }
            Button("Read saved messages from phone…") { Task { await model.readHistory() } }
            Button("Phone connection…") { connection = CompanionConnectionModel() }
            Button("Manage picture library…", action: onImages)
            if !model.pictures.isEmpty {
                Menu("Saved pictures") {
                    ForEach(Array(model.pictures.enumerated()), id: \.element.id) { index, picture in
                        Menu("Picture \(index + 1) · \(formatted(picture.importedAt))") {
                            Button("Unlink from conversation") {
                                Task { await model.changePicture(picture, removeMacCopy: false) }
                            }
                            Button("Remove Mac copy…", role: .destructive) { pictureToRemove = picture }
                        }
                    }
                }
            }
            if model.history != nil {
                Button("Remove saved messages from this Mac", role: .destructive) { model.unlinkHistory() }
            }
            if model.record != nil {
                Divider()
                Toggle("Refresh while open", isOn: $model.automatic)
                Toggle("Show every saved preview", isOn: $model.showOriginalCaptures)
                Button("Unlink source and delete cached previews", role: .destructive) { model.unlink() }
            }
        } label: {
            Image(systemName: "ellipsis").frame(width: 28, height: 28)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .disabled(model.busy || confirmingSource)
            .help("Conversation options").accessibilityLabel("Conversation options")
    }
}

struct PhoneConversationSampleView: View {
    let sample: PhoneNotificationSnapshot
    static func linkedText(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, url.scheme?.lowercased() == "https", url.host != nil,
                  url.user == nil, url.password == nil, let range = Range(match.range, in: text),
                  let start = AttributedString.Index(range.lowerBound, within: result),
                  let end = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[start..<end].link = url
        }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Captured \(Date(timeIntervalSince1970: Double(sample.capturedAtMS) / 1000).formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(sample.messages.enumerated()), id: \.offset) { _, message in
                if !message.text.isEmpty {
                    PhonePreviewMessageView(message: message, capturedAtMS: sample.capturedAtMS)
                }
            }
            PhonePreviewPictureView(sample: sample)
            if sample.uriAttachments > 0 || ["UNSUPPORTED", "UNAVAILABLE"].contains(sample.imageState) {
                Text("Some referenced graphics could not be recovered. Use Shared graphics for an explicit image import.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Partial notification preview · direction and complete history are not established.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
