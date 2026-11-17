import SwiftUI

struct PhoneHistoryView: View {
    let snapshot: PhoneHistorySnapshot
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            Text("Saved from your phone · \(snapshot.messages.count) messages · \(Date(timeIntervalSince1970: Double(snapshot.capturedAtMS) / 1000).formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            if snapshot.limited || snapshot.sms != "OK" || snapshot.mms != "OK" {
                Text("Only part of this conversation could be saved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if snapshot.messages.isEmpty { Text("No messages were saved.") }
            ForEach(snapshot.messages) { row in
                HStack {
                    if row.direction == "SENT" { Spacer(minLength: 24) }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.text.isEmpty ? AttributedString("[No saved text]") : PhoneConversationSampleView.linkedText(row.text))
                            .textSelection(.enabled)
                        HStack {
                            Text(row.direction == "SENT" ? "Sent" : row.direction == "RECEIVED" ? "Received" : "Sent or received status unavailable")
                            if row.timestampMS > 0 {
                                Text(Date(timeIntervalSince1970: Double(row.timestampMS) / 1000).formatted(date: .abbreviated, time: .shortened))
                            } else { Text("Time unavailable") }
                        }.font(.caption).foregroundStyle(.secondary)
                        if row.truncated { Text("Text shortened").font(.caption).foregroundStyle(.secondary) }
                        if row.attachmentsOmitted > 0 || !row.partsComplete {
                            Text("Some pictures or attachments weren’t saved.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(12).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: 640, alignment: row.direction == "SENT" ? .trailing : .leading)
                    if row.direction != "SENT" { Spacer(minLength: 0) }
                }
            }
            Text("Some messages and pictures may be missing. To update this copy, save the conversation again in the Android companion.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
