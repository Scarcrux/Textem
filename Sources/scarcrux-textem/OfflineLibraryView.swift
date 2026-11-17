import AppKit
import SwiftUI

@MainActor final class OfflineLibraryModel: ObservableObject {
    let saved: SavedPhoneConversationsModel
    let images: PhoneImagesModel
    @Published var showPictures = false
    init(accountID: UUID, previews: URL = PhoneConversationStore.directory,
         history: URL = PhoneHistoryStore.directory, pictures: URL = PhoneImageStore.directory) {
        saved = SavedPhoneConversationsModel(accountID: accountID, directory: previews, historyDirectory: history)
        saved.showHistory = !saved.histories.isEmpty
        images = PhoneImagesModel(directory: pictures)
        images.selectedID = images.images.first?.id
    }
}

struct OfflineLibraryView: View {
    @ObservedObject var model: OfflineLibraryModel
    var goOnline: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "wifi.slash").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Offline Mode").font(.headline)
                    Text("Saved on this Mac · live Messages and phone loading paused").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Go Online", action: goOnline)
            }.padding(20)
            Text("Saved phone history, previews and imported pictures are available here. Ordinary web conversations aren’t stored offline.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.bottom, 12)
            Picker("Saved content", selection: $model.showPictures) {
                Text("History and previews").tag(false)
                Text("Imported pictures").tag(true)
            }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.bottom, 14)
            Divider()
            if model.showPictures {
                OfflinePicturesView(model: model.images)
            } else {
                SavedPhoneConversationsView(model: model.saved, onClose: {}, showHeader: false)
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct OfflinePicturesView: View {
    @ObservedObject var model: PhoneImagesModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Imported pictures · local library").font(.headline)
            if model.images.isEmpty {
                Text("No imported pictures are saved on this Mac.").foregroundStyle(.secondary)
            } else {
                Picker("Picture", selection: $model.selectedID) {
                    ForEach(Array(model.images.enumerated()), id: \.element.id) { index, image in
                        Text("Picture \(index + 1) · \(image.importedAt.formatted(date: .abbreviated, time: .shortened))").tag(Optional(image.id))
                    }
                }
                if let graphic = model.graphic {
                    Image(nsImage: graphic).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Saved imported phone picture")
                }
            }
            Spacer(minLength: 0)
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
