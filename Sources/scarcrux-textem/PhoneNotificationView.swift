import AppKit
import SwiftUI
import NativeAutoFillCore

@MainActor
final class PhoneNotificationModel: ObservableObject {
    @Published var snapshot: PhoneNotificationSnapshot?
    @Published var endpoint: String
    @Published var busy = false
    @Published var status = "Requires companion v0.9 with local content samples enabled. Reads one saved notification preview—not complete history."
    private var requestID = UUID()
    let directory: URL
    private let persistEndpoint: Bool
    private let revokeCodes: @MainActor (PhoneNotificationSnapshot) throws -> Void
    let fetch: @Sendable (String) async throws -> PhoneNotificationSnapshot
    init(directory: URL = PhoneNotificationStore.directory, persistEndpoint: Bool = true,
         fetch: @escaping @Sendable (String) async throws -> PhoneNotificationSnapshot = { try await PhoneImageADBClient.shared.fetchNotification(endpoint: $0) },
         revokeCodes: @escaping @MainActor (PhoneNotificationSnapshot) throws -> Void = { try NativeAutoFillCoordinator.shared.clearSource($0) }) {
        self.directory = directory; self.fetch = fetch; self.persistEndpoint = persistEndpoint
        self.revokeCodes = revokeCodes
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
            if persistEndpoint { await NativeAutoFillCoordinator.shared.ingest(value) }
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
            if persistEndpoint, let snapshot { try revokeCodes(snapshot) }
            if FileManager.default.fileExists(atPath: directory.path) { try PhoneNotificationStore.clear(in: directory) }
            snapshot = nil; status = "Mac sample deleted. The phone sample, original messages and shared-image library are unchanged."
        } catch let error as CodeVaultError {
            status = "Mac sample retained because native code revocation failed. " + error.localizedDescription
        } catch { status = PhoneNotificationError.privateFile.localizedDescription }
    }
}

struct PhoneNotificationView: View {
    @ObservedObject var model: PhoneNotificationModel
    @ObservedObject var nativeCodes = NativeAutoFillCoordinator.shared
    var codeAccounts: [Account] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PhonePanelHeader(symbol: "text.bubble", title: "Phone Notification Preview",
                             subtitle: "Separate local sample · not linked to a web conversation")
                .padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Wireless debugging IP:port (optional for USB)", text: $model.endpoint)
                        .textFieldStyle(.roundedBorder).disabled(model.busy).accessibilityIdentifier("notification-endpoint")
                    Button("Read latest phone sample") { Task { await model.readFromPhone() } }
                        .keyboardShortcut(.defaultAction).disabled(model.busy)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if nativeCodes.enabled, let snapshot = model.snapshot, !codeAccounts.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Menu("Link this code source to an account…") {
                                ForEach(codeAccounts) { account in
                                    Button(account.name) { Task { await NativeAutoFillCoordinator.shared.bind(snapshot, accountID: account.id) } }
                                }
                            }.disabled(model.busy).fixedSize()
                            Text("Links only this phone installation and notification source for verification codes. It does not attach message history or graphics to a web thread.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Text(nativeCodes.status).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }
                }
            }.padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            if let snapshot = model.snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(verbatim: snapshot.title.isEmpty ? "Unnamed Google Messages source" : snapshot.title)
                                .font(.title3.weight(.semibold)).accessibilityIdentifier("notification-source")
                            Spacer()
                            Button("Delete Mac sample", role: .destructive) { model.clear() }.disabled(model.busy)
                        }
                        Text("Captured \(Date(timeIntervalSince1970: Double(snapshot.capturedAtMS) / 1000).formatted(date: .abbreviated, time: .shortened)) · saved snapshot, not a live inbox")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(snapshot.messages.enumerated()), id: \.offset) { index, message in
                            if !message.text.isEmpty {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(verbatim: message.text).textSelection(.enabled)
                                        .accessibilityIdentifier("notification-message-\(index)")
                                    HStack(spacing: 6) {
                                        Text(message.timestampMS > 0 ? Date(timeIntervalSince1970: Double(message.timestampMS) / 1000).formatted(date: .abbreviated, time: .shortened) : "Message time not supplied")
                                        if message.truncated { Text("· Preview capped") }
                                    }.font(.caption2).foregroundStyle(.secondary)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
                            }
                        }
                        if let data = snapshot.image?.data, let image = NSImage(data: data) {
                            Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 340)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .accessibilityLabel("Saved notification picture preview").accessibilityIdentifier("notification-picture")
                            note("Notification-level picture preview · not assigned to a specific message")
                        } else { note("No usable picture in this saved notification sample.") }
                        if snapshot.uriAttachments > 0 { note("\(snapshot.uriAttachments) attachment reference(s) were not opened. Their graphics are not recovered.") }
                        if snapshot.imageState == "UNAVAILABLE" || snapshot.imageState == "UNSUPPORTED" {
                            note("The notification’s picture was unavailable or unsupported; no graphic was inferred.")
                        }
                        if snapshot.truncated { note("The sample reached a title/message cap.") }
                        note("Notification previews may omit or shorten messages and images. Message direction and full history are not established.")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }
            } else {
                PhoneEmptyState(symbol: "text.bubble", title: "No notification preview saved on this Mac",
                                detail: "Enable local content samples in the phone companion and use Read latest phone sample. This does not replace the shared-image library or recover historical business cards.",
                                titleIdentifier: "notification-empty")
            }
        }.frame(minWidth: 500, minHeight: 600).background(Color(nsColor: .windowBackgroundColor))
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
final class PhoneNotificationWindowController: NSWindowController, NSWindowDelegate {
    let model = PhoneNotificationModel()
    init() {
        let host = NSHostingController(rootView: PhoneNotificationView(model: model, codeAccounts: AccountStore.shared.accounts))
        let window = NSWindow(contentViewController: host)
        window.title = "Phone Notification Preview"; window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 680, height: 780)); window.minSize = NSSize(width: 520, height: 640)
        window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self; window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func windowWillClose(_ notification: Notification) { model.cancel() }
}
