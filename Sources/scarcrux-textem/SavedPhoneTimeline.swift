import AppKit
import SwiftUI

/// Dates describe the source we actually have. An imported or captured
/// picture has no trustworthy message timestamp or direction.
struct SavedPhoneTimeline {
    enum Item: Identifiable {
        case history(PhoneHistorySnapshot.Message)
        case preview(PhonePreviewPresentation.Row)
        case capturedPicture(PhoneNotificationSnapshot, Int)
        case importedPicture(ImportedPhoneImage)

        var id: String {
            switch self {
            case .history(let row): "history-" + row.id
            case .preview(let row): "preview-\(row.id)"
            case .capturedPicture(let sample, let index): "capture-\(sample.capturedAtMS)-\(index)"
            case .importedPicture(let image): "import-" + image.id.uuidString
            }
        }

        var date: Date? {
            switch self {
            case .history(let row): row.timestampMS > 0 ? Self.date(row.timestampMS) : nil
            case .preview(let row): Self.date(row.message.timestampMS > 0 ? row.message.timestampMS : row.capturedAtMS)
            case .capturedPicture(let sample, _): Self.date(sample.capturedAtMS)
            case .importedPicture(let image): image.importedAt
            }
        }

        private static func date(_ milliseconds: Int64) -> Date {
            Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        }
    }

    let items: [Item]

    init(history: PhoneHistorySnapshot?, samples: [PhoneNotificationSnapshot], pictures: [ImportedPhoneImage],
         showOriginalCaptures: Bool) {
        let previews = PhonePreviewPresentation(samples: samples)
        var entries = history?.messages.map(Item.history) ?? []
        if history == nil && !showOriginalCaptures {
            entries += previews.messages.map(Item.preview)
        }
        if !showOriginalCaptures {
            entries += previews.pictureCaptures.enumerated().map { .capturedPicture($0.element, $0.offset) }
        }
        entries += pictures.map(Item.importedPicture)
        items = entries.enumerated().sorted { lhs, rhs in
            switch (lhs.element.date, rhs.element.date) {
            case let (left?, right?) where left != right: return left < right
            case (nil, _?): return false
            case (_?, nil): return true
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}

struct SavedPhonePictureBubble: View {
    let image: NSImage
    let caption: String
    @State private var enlarged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { enlarged = true } label: {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: 320, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Enlarge saved picture")
            .help("Enlarge saved picture")
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $enlarged) {
            VStack(alignment: .trailing, spacing: 12) {
                Button("Done") { enlarged = false }.keyboardShortcut(.cancelAction)
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: 680, maxHeight: 480)
                    .accessibilityLabel("Saved picture")
            }.padding(16)
        }
    }
}
