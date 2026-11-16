import AppKit
import Darwin
import SwiftUI

@MainActor final class CompanionConnectionModel: ObservableObject {
    @Published private(set) var paired = false
    @Published private(set) var status = "No phone connection imported. Existing developer setup is available."
    private let load: () throws -> Data?
    private let save: (Data) throws -> Void
    init(load: @escaping () throws -> Data? = { try CompanionCredentialStore().load() },
         save: @escaping (Data) throws -> Void = { try CompanionCredentialStore().save($0) }) {
        self.load = load; self.save = save; refresh()
    }
    func refresh() {
        do {
            guard let data = try load() else { paired = false; return }
            if data.isEmpty { paired = false; status = CompanionConnectionError.disconnected.localizedDescription; return }
            _ = try CompanionPairing.parse(data); paired = true
            status = "Phone connection saved in this Mac’s Keychain. Keep the phone connection running on the same private network. Reachability has not been checked."
        } catch { paired = false; status = "Couldn’t read the protected phone connection. No debugging fallback will be used." }
    }
    func importData(_ data: Data) throws {
        _ = try CompanionPairing.parse(data); try save(data); refresh()
        status = "Phone connection imported. Delete the transferred connection file after setup; it grants access to captured previews. Refresh previews to check the connection."
    }
    func chooseFile(onChanged: () -> Void) {
        let panel = NSOpenPanel(); panel.title = "Import Textem phone connection"
        panel.message = "Choose the private .textempair file exported by your phone. This file grants preview access; share it only with your Mac."
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw CompanionConnectionError.invalidPairing }; defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_size > 0, info.st_size <= 4096 else { throw CompanionConnectionError.invalidPairing }
            var buffer = [UInt8](repeating: 0, count: 4097)
            let count = read(fd, &buffer, buffer.count)
            guard count == Int(info.st_size) else { throw CompanionConnectionError.invalidPairing }
            try importData(Data(buffer.prefix(count))); onChanged()
        } catch { status = "Couldn’t import the phone connection. " + error.localizedDescription }
    }
    func disconnect() throws {
        do { try save(Data()) } catch {
            status = "Couldn’t disconnect in Keychain. The existing connection remains configured."; throw error
        }
        paired = false
        status = "Disconnected on this Mac. Cached previews are retained. Stop and revoke the connection on your phone to invalidate every copy of its connection file."
    }
}

struct CompanionConnectionView: View {
    @ObservedObject var model: CompanionConnectionModel
    var onChanged: () -> Void
    var onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Phone connection").font(.title2.bold())
            Text("On your phone, open Textem → Automatic recovery setup → Start local connection. Export its connection file privately to this Mac, then import it here.")
                .fixedSize(horizontal: false, vertical: true)
            Text("This connects captured notification previews over encrypted local Wi-Fi. It does not recover full history. Start in the phone companion enables automatic resume until Stop or revocation. Textem rediscovers the same pinned phone after address changes; discovery never grants trust.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(model.status).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Import phone connection…") { model.chooseFile(onChanged: onChanged) }
                Button("Disconnect", role: .destructive) {
                    do { try model.disconnect(); onChanged() } catch { /* The existing connection remains protected. */ }
                }.disabled(!model.paired)
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 540)
    }
}
