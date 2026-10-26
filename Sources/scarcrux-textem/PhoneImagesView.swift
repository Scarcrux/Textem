import AppKit
import SwiftUI

@MainActor
final class PhoneImagesModel: ObservableObject {
    @Published var images: [ImportedPhoneImage] = []
    @Published var selectedID: UUID?
    @Published var status = "Share a graphic on your phone → Textem Share Probe → Save image for Mac. Then import here."
    @Published var busy = false
    @Published var endpoint: String
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
    func reload() {
        do { images = try PhoneImageStore.load(in: directory) }
        catch { status = (error as? PhoneImageError ?? .privateFile).localizedDescription }
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
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "photo.on.rectangle").font(.title2)
                VStack(alignment: .leading) {
                    Text("Shared Phone Images").font(.headline)
                    Text("Explicit shares · local Mac library").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.plain)
                    .accessibilityLabel("Close shared phone images")
            }.padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                TextField("Wireless debugging IP:port (optional for USB)", text: $model.endpoint)
                    .textFieldStyle(.roundedBorder).disabled(model.busy)
                    .accessibilityLabel("Phone wireless debugging address")
                HStack {
                    Button("Import from phone") { Task { await model.importFromPhone() } }.disabled(model.busy)
                    if model.busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Remove Mac copy") { model.removeSelected() }.disabled(model.busy || model.selected == nil)
                }
                Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }.padding(.horizontal, 20).padding(.bottom, 14)
            Divider()
            if !model.images.isEmpty {
                Picker("Saved image", selection: Binding(get: { model.selected?.id ?? model.images[0].id }, set: { model.selectedID = $0 })) {
                    ForEach(model.images) { image in
                        Text("\(image.importedAt.formatted(date: .abbreviated, time: .shortened)) · \(image.width)×\(image.height)").tag(image.id)
                    }
                }.padding(.horizontal, 20).padding(.top, 12)
            }
            if let graphic = model.graphic {
                Image(nsImage: graphic).resizable().scaledToFit().padding(20)
                    .accessibilityLabel("Imported shared phone graphic")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "photo").font(.system(size: 42))
                    Text(model.images.isEmpty ? "No imported images yet" : "Saved image unavailable or refused")
                    Text("This imports individual shared graphics, not complete conversations or background history.")
                        .font(.caption).multilineTextAlignment(.center)
                }.foregroundStyle(.secondary).padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
