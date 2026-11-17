import AppKit
import SwiftUI

@MainActor
final class PhoneImagesModel: ObservableObject {
    @Published var images: [ImportedPhoneImage] = []
    @Published var selectedID: UUID?
    @Published var status = "Share a graphic on your phone → Textem Share Probe → Save image for Mac. Then import here."
    @Published var busy = false
    @Published var endpoint: String
    @Published private(set) var conversation: PhoneImageConversation?
    @Published private(set) var conversationOnly = false
    @Published private(set) var bindings: [PhoneImageBinding] = []
    var validateConversation: ((PhoneImageConversation) async -> Bool)?
    let directory: URL
    let client: PhoneImageADBClient
    init(directory: URL = PhoneImageStore.directory, client: PhoneImageADBClient = .shared) {
        self.directory = directory; self.client = client
        endpoint = UserDefaults.standard.string(forKey: "phoneImageEndpoint") ?? ""
        reload()
    }
    var selected: ImportedPhoneImage? { images.first { $0.id == selectedID } ?? images.first }
    var graphic: NSImage? {
        guard let selected, let data = try? PhoneImageStore.imageData(selected, in: directory) else { return nil }
        return NSImage(data: data)
    }
    var selectedBinding: PhoneImageBinding? { bindings.first { $0.imageID == selected?.id } }
    func setConversation(_ value: PhoneImageConversation?, only: Bool? = nil) {
        let changed = conversation != value || (only != nil && only != conversationOnly)
        conversation = value
        if let only { conversationOnly = only }
        if changed { selectedID = nil; reload() }
    }
    func reload() {
        do {
            bindings = try PhoneImageStore.loadBindings(in: directory)
            images = conversationOnly ? (try conversation.map { try PhoneImageStore.images(for: $0, in: directory) } ?? [])
                : try PhoneImageStore.load(in: directory)
        } catch {
            images = []; bindings = []; selectedID = nil
            status = (error as? PhoneImageError ?? .privateFile).localizedDescription
        }
    }
    func linkSelected(to expected: PhoneImageConversation) async {
        guard !busy, let image = selected, let key = expected.key, conversation?.key == key else { return }
        busy = true; defer { busy = false }
        guard let validateConversation, await validateConversation(expected),
              conversation?.key == key, selected?.id == image.id else {
            status = "Conversation changed or could not be verified. Nothing was linked."; return
        }
        do {
            try PhoneImageStore.link(image, to: expected, in: directory); reload()
            status = "Linked explicitly. This image will appear when this account and conversation open."
        } catch { status = (error as? PhoneImageError ?? .privateFile).localizedDescription }
    }
    func unlinkSelected() {
        guard !busy, let image = selected else { return }
        do {
            try PhoneImageStore.unlink(image, in: directory); reload()
            status = "Conversation link removed. The saved image and phone original are unchanged."
        } catch { status = (error as? PhoneImageError ?? .privateFile).localizedDescription }
    }
    func importFromPhone() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        let address = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.isEmpty && !PhoneImageADBClient.validEndpoint(address) {
            status = "Enter a private IPv4 address and port from Wireless debugging, or leave blank for one connected USB/paired phone."; return
        }
        UserDefaults.standard.set(address, forKey: "phoneImageEndpoint")
        status = "Connecting over the encrypted developer connection…"
        do {
            let client = self.client
            let (manifest, data) = try await Task.detached { try await client.fetch(endpoint: address) }.value
            try OfflineMode.requireOnline()
            let alreadyImported = images.contains { $0.sha256 == manifest.sha256 }
            let imported = try PhoneImageStore.importImage(manifest: manifest, png: data, in: directory)
            reload(); selectedID = imported.id
            status = alreadyImported ? "This saved image is already in your Mac library."
                : "Imported one shared phone image. Stored only on this Mac; no conversation was guessed."
        } catch { status = (error as? PhoneImageError ?? .connection).localizedDescription }
    }
    func removeSelected() {
        guard !busy, let selected else { return }
        do {
            try PhoneImageStore.remove(selected, in: directory); selectedID = nil; reload()
            status = "Removed this Mac copy. The original on your phone is unchanged."
        } catch { status = (error as? PhoneImageError ?? .privateFile).localizedDescription }
    }
}

struct PhoneImagesView: View {
    @ObservedObject var model: PhoneImagesModel
    let onClose: () -> Void
    var onOpenLibrary: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 0) {
            PhonePanelHeader(
                symbol: "photo.on.rectangle",
                title: model.conversationOnly ? "Saved Conversation Images" : "Shared Phone Images",
                subtitle: model.conversationOnly ? "Explicitly linked · this account and thread only" : "Explicit shares · local Mac library",
                onClose: onClose, closeLabel: "Close shared phone images").padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if model.conversationOnly {
                        if let onOpenLibrary { Button("Manage shared images", action: onOpenLibrary) }
                        Spacer()
                    } else {
                        TextField("Wireless debugging IP:port (optional for USB)", text: $model.endpoint)
                            .textFieldStyle(.roundedBorder).disabled(model.busy)
                            .accessibilityLabel("Phone wireless debugging address")
                        Button("Import from phone") { Task { await model.importFromPhone() } }
                            .keyboardShortcut(.defaultAction).disabled(model.busy)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let conversation = model.conversation {
                    Text("Conversation: \(conversation.label)").font(.subheadline).lineLimit(2)
                    HStack {
                        if !model.conversationOnly {
                            Button("Link image to this conversation") { Task { await model.linkSelected(to: conversation) } }
                                .disabled(model.busy || model.selected == nil || model.selectedBinding != nil)
                        }
                        Button("Unlink image") { model.unlinkSelected() }
                            .disabled(model.busy || model.selectedBinding == nil)
                    }
                    Text("Link only after checking that this graphic belongs here. Textem cannot infer its source thread.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("To link a graphic, select a phone-only conversation in the inbox. A verified account and route are required.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            if !model.images.isEmpty {
                HStack {
                    Picker("Saved image", selection: Binding(get: { model.selected?.id ?? model.images[0].id }, set: { model.selectedID = $0 })) {
                        ForEach(model.images) { image in
                            Text("\(image.importedAt.formatted(date: .abbreviated, time: .shortened)) · \(image.width)×\(image.height)").tag(image.id)
                        }
                    }
                    Button("Remove Mac copy", role: .destructive) { model.removeSelected() }
                        .disabled(model.busy || model.selected == nil)
                }.padding(.horizontal, 20).padding(.top, 12)
            }
            if let graphic = model.graphic {
                Image(nsImage: graphic).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(20)
                    .accessibilityLabel("Imported shared phone graphic")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PhoneEmptyState(
                    symbol: "photo",
                    title: model.images.isEmpty ? (model.conversationOnly ? "No images linked to this conversation" : "No imported images yet") : "Saved image unavailable or refused",
                    detail: "Individual shared graphics only · no complete conversation or background history recovery.")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
