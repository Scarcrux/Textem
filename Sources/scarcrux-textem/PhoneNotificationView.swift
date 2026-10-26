import AppKit
import SwiftUI

@MainActor
final class PhoneNotificationModel: ObservableObject {
    @Published var snapshot: PhoneNotificationSnapshot?
    @Published var endpoint: String
    @Published var busy = false
    @Published var status = "Requires companion v0.9 with local content samples enabled. Reads one saved notification preview—not complete history."
    private var requestID = UUID()
    let directory: URL
    private let persistEndpoint: Bool
    let fetch: @Sendable (String) async throws -> PhoneNotificationSnapshot
    init(directory: URL = PhoneNotificationStore.directory, persistEndpoint: Bool = true,
         fetch: @escaping @Sendable (String) async throws -> PhoneNotificationSnapshot = { try await PhoneImageADBClient.shared.fetchNotification(endpoint: $0) }) {
        self.directory = directory; self.fetch = fetch; self.persistEndpoint = persistEndpoint
        endpoint = UserDefaults.standard.string(forKey: "phoneImageEndpoint") ?? ""
        do { snapshot = try PhoneNotificationStore.load(in: directory) }
        catch { status = (error as? PhoneNotificationError ?? .privateFile).localizedDescription }
    }
    func cancel() { requestID = UUID(); busy = false }
    func readFromPhone() async {
        guard !busy else { return }
        let address = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.isEmpty || PhoneImageADBClient.validEndpoint(address) else {
            status = "Use the phone’s private Wireless debugging IP:port, or leave blank for one authorized USB/paired phone."; return
        }
        let id = UUID(); requestID = id; busy = true
        status = "Reading the saved sample over the authenticated developer connection…"
        defer { if requestID == id { busy = false } }
        do {
            let fetch = self.fetch
            let value = try await Task.detached { try await fetch(address) }.value
            guard requestID == id else { return }
            try PhoneNotificationStore.save(value, in: directory)
            if persistEndpoint { UserDefaults.standard.set(address, forKey: "phoneImageEndpoint") }
            snapshot = value; status = "Imported one private notification preview. No web account or conversation was guessed."
        } catch {
            guard requestID == id else { return }
            if let error = error as? PhoneNotificationError { status = error.localizedDescription }
            else if let error = error as? PhoneImageError, [.adbMissing, .noDevice, .tlsRequired].contains(error) { status = error.localizedDescription }
            else { status = "Phone transfer failed or timed out. Check the connection and companion. The previous Mac sample is unchanged." }
        }
    }
    func clear() {
        guard !busy else { return }
        do {
            if FileManager.default.fileExists(atPath: directory.path) { try PhoneNotificationStore.clear(in: directory) }
            snapshot = nil; status = "Mac sample deleted. The phone sample, original messages and shared-image library are unchanged."
        } catch { status = PhoneNotificationError.privateFile.localizedDescription }
    }
}

struct PhoneNotificationView: View {
    @ObservedObject var model: PhoneNotificationModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Phone Notification Preview", systemImage: "text.bubble").font(.title2)
            Text("Separate local sample · not linked to a web conversation").font(.subheadline).foregroundStyle(.secondary)
            TextField("Wireless debugging IP:port (optional for USB)", text: $model.endpoint)
                .textFieldStyle(.roundedBorder).disabled(model.busy).accessibilityIdentifier("notification-endpoint")
            HStack {
                Button("Read latest phone sample") { Task { await model.readFromPhone() } }.disabled(model.busy)
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Delete Mac sample") { model.clear() }.disabled(model.busy || model.snapshot == nil)
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    if let snapshot = model.snapshot {
                        Text(verbatim: snapshot.title.isEmpty ? "Unnamed Google Messages source" : snapshot.title)
                            .font(.headline).accessibilityIdentifier("notification-source")
                        Text("Captured \(Date(timeIntervalSince1970: Double(snapshot.capturedAtMS) / 1000).formatted(date: .abbreviated, time: .shortened)) · saved snapshot, not a live inbox")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Notification previews may omit or shorten messages and images. Message direction and full history are not established.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(snapshot.messages.enumerated()), id: \.offset) { index, message in
                            if !message.text.isEmpty {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(verbatim: message.text).textSelection(.enabled)
                                        .accessibilityIdentifier("notification-message-\(index)")
                                    Text(message.timestampMS > 0 ? Date(timeIntervalSince1970: Double(message.timestampMS) / 1000).formatted(date: .abbreviated, time: .shortened) : "Message time not supplied")
                                        .font(.caption2).foregroundStyle(.secondary)
                                    if message.truncated { Text("Preview capped").font(.caption2).foregroundStyle(.secondary) }
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                        if let data = snapshot.image?.data, let image = NSImage(data: data) {
                            Text("Notification-level picture preview · not assigned to a specific message").font(.caption).foregroundStyle(.secondary)
                            Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 340)
                                .accessibilityLabel("Saved notification picture preview").accessibilityIdentifier("notification-picture")
                        } else { Text("No usable picture in this saved notification sample.").font(.caption).foregroundStyle(.secondary) }
                        if snapshot.uriAttachments > 0 { Text("\(snapshot.uriAttachments) attachment reference(s) were not opened. Their graphics are not recovered.").font(.caption).foregroundStyle(.secondary) }
                        if snapshot.imageState == "UNAVAILABLE" || snapshot.imageState == "UNSUPPORTED" {
                            Text("The notification’s picture was unavailable or unsupported; no graphic was inferred.").font(.caption).foregroundStyle(.secondary)
                        }
                        if snapshot.truncated { Text("The sample reached a title/message cap.").font(.caption).foregroundStyle(.secondary) }
                    } else {
                        Text("No notification preview saved on this Mac").font(.headline).accessibilityIdentifier("notification-empty")
                        Text("Enable local content samples in the phone companion and use Read latest phone sample. This does not replace the shared-image library or recover historical business cards.")
                            .foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
            }
        }.padding(22).frame(minWidth: 500, minHeight: 600).background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor
final class PhoneNotificationWindowController: NSWindowController, NSWindowDelegate {
    let model = PhoneNotificationModel()
    init() {
        let host = NSHostingController(rootView: PhoneNotificationView(model: model))
        let window = NSWindow(contentViewController: host)
        window.title = "Phone Notification Preview"; window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 680, height: 780)); window.minSize = NSSize(width: 520, height: 640)
        window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self; window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowWillClose(_ notification: Notification) { model.cancel() }
}
