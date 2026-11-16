import AppKit
import SwiftUI

@MainActor final class PhoneConversationModel: ObservableObject {
    let context: PhoneImageConversation
    let directory: URL
    @Published private(set) var record: PhoneConversationStore.Record?
    @Published private(set) var candidate: PhoneNotificationSnapshot?
    @Published private(set) var candidates: [PhoneNotificationSnapshot] = []
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
         fetch: @escaping @Sendable (String) async throws -> PhoneNotificationJournal = { try await CompanionJournalTransport().fetch(developerEndpoint: $0) }) {
        self.context = context; self.directory = directory; self.endpoint = endpoint; self.fetch = fetch
        reload()
        if record != nil { status = "Saved phone previews for this account and conversation." }
    }
    func reload() {
        do { record = try PhoneConversationStore.record(for: context, in: directory) }
        catch { record = nil; status = error.localizedDescription }
    }
    func cancel() { stopped = true; generation = UUID(); busy = false; candidate = nil; candidates = [] }
    func connectionChanged() {
        generation = UUID(); busy = false; candidate = nil; candidates = []
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
        generation = UUID(); busy = false; candidate = nil; candidates = []
        lastSuccessfulRefresh = nil; lastRefreshTransport = .unknown
        do {
            try PhoneConversationStore.unlink(context, in: directory); reload()
            status = "Source unlinked and this conversation’s cached previews deleted. Phone originals and shared images are unchanged."
        } catch { status = error.localizedDescription }
    }
    func run() async {
        while !stopped && !Task.isCancelled {
            if record != nil && automatic { await read() }
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
        }
    }
}

struct PhoneConversationView: View {
    @ObservedObject var model: PhoneConversationModel
    var onClose: () -> Void
    var onImages: () -> Void
    @State private var connection: CompanionConnectionModel?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PhonePanelHeader(symbol: "iphone.and.arrow.forward", title: "Phone conversation previews",
                subtitle: model.context.label, onClose: onClose, closeLabel: "Close phone conversation previews",
                trailingActions: AnyView(headerActions)).padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            HStack(alignment: .top, spacing: 12) {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if model.record == nil {
                    Button("Read phone preview") { Task { await model.read() } }.disabled(model.busy)
                }
            }.padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let candidate = model.candidate {
                        Text("Confirm phone source").font(.headline)
                        Picker("Captured phone source", selection: Binding(get: { PhoneConversationStore.sourceKey(candidate) }, set: { model.chooseSource($0) })) {
                            ForEach(model.candidates, id: \.sourceKey) { sample in
                                Text(verbatim: sample.title.isEmpty ? "Unnamed phone source" : sample.title).tag(PhoneConversationStore.sourceKey(sample))
                            }
                        }.disabled(model.busy)
                        Text(verbatim: candidate.title.isEmpty ? "Unnamed phone source" : candidate.title).font(.subheadline)
                        PhoneConversationSampleView(sample: candidate)
                        Button("This belongs here — link and refresh previews") { Task { await model.link() } }.disabled(model.busy)
                    } else if let record = model.record {
                        PhonePreviewListView(samples: record.samples, showOriginalCaptures: model.showOriginalCaptures)
                    } else {
                        Text("No phone source linked").font(.headline)
                        Text("Read a phone preview, check its source and content, then explicitly link it here. Textem will not guess from a sender name.")
                            .foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
        }.background(Color(nsColor: .windowBackgroundColor))
            .sheet(isPresented: Binding(get: { connection != nil }, set: { if !$0 { connection = nil } })) {
                if let connection { CompanionConnectionView(model: connection, onChanged: model.connectionChanged, onClose: { self.connection = nil }) }
            }
            .task { await model.run() }.onDisappear { model.cancel() }
    }
    private var headerActions: some View {
        HStack(spacing: 8) {
            if model.record != nil {
                Button { Task { await model.read() } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
                }.buttonStyle(.plain).disabled(model.busy)
                    .help("Refresh phone previews").accessibilityLabel("Refresh phone previews")
            }
            Menu {
                Button("Phone connection…") { connection = CompanionConnectionModel() }
                Button("Shared graphics", action: onImages)
                if model.record != nil {
                    Divider()
                    Toggle("Refresh while open", isOn: $model.automatic)
                    Toggle("Show original captures", isOn: $model.showOriginalCaptures)
                    Divider()
                    Button("Unlink source and delete cached previews", role: .destructive) { model.unlink() }.disabled(model.busy)
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 28)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Conversation options").accessibilityLabel("Conversation options")
        }
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
