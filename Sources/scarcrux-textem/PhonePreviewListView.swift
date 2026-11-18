import AppKit
import SwiftUI

struct PhonePreviewMessageView: View {
    let message: PhoneNotificationSnapshot.Message
    let capturedAtMS: Int64
    var inTimeline = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(PhoneConversationSampleView.linkedText(message.text)).textSelection(.enabled)
            HStack {
                if message.timestampMS > 0 {
                    Text(Date(timeIntervalSince1970: Double(message.timestampMS) / 1000).formatted(date: inTimeline ? .omitted : .abbreviated, time: .shortened))
                } else {
                    Text("Captured \(Date(timeIntervalSince1970: Double(capturedAtMS) / 1000).formatted(date: inTimeline ? .omitted : .abbreviated, time: .shortened)) · message time unavailable")
                }
                if message.truncated { Text("Shortened preview") }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(12)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PhonePreviewPictureView: View {
    let sample: PhoneNotificationSnapshot
    var body: some View {
        if let data = sample.image?.data, let image = NSImage(data: data) {
            VStack(alignment: .leading, spacing: 6) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 400)
                    .accessibilityLabel("Captured phone notification picture")
                Text("Picture captured \(Date(timeIntervalSince1970: Double(sample.capturedAtMS) / 1000).formatted(date: .abbreviated, time: .shortened)). Its individual message wasn’t supplied.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct PhonePreviewListView: View {
    let samples: [PhoneNotificationSnapshot]
    let showOriginalCaptures: Bool
    var body: some View {
        let presentation = PhonePreviewPresentation(samples: samples)
        VStack(alignment: .leading, spacing: 16) {
            if showOriginalCaptures {
                Text("All saved previews").font(.headline)
                Text("Each saved preview is shown separately, including repeated messages.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                    PhoneConversationSampleView(sample: sample)
                }
            } else {
                ForEach(presentation.messages) { row in
                    PhonePreviewMessageView(message: row.message, capturedAtMS: row.capturedAtMS)
                }
                ForEach(Array(presentation.pictureCaptures.enumerated()), id: \.offset) { _, sample in
                    PhonePreviewPictureView(sample: sample)
                }
                if presentation.hasMissingPictures {
                    Text("Some referenced pictures weren’t captured. Use Phone → Shared Phone Images… to import an image explicitly.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Partial phone previews. Older messages, pictures and actions may be missing; sent/received direction wasn’t supplied.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
