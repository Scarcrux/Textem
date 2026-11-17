import SwiftUI

struct PhoneHistoryView: View {
    let snapshot: PhoneHistorySnapshot
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            Text("Selected phone history").font(.headline)
            Text("Published \(Date(timeIntervalSince1970: Double(snapshot.capturedAtMS) / 1000).formatted(date: .abbreviated, time: .shortened)) · \(snapshot.messages.count) provider rows")
                .font(.caption).foregroundStyle(.secondary)
            Text("SMS/MMS provider text. RCS-only content and attachments may be missing. To update this snapshot, publish the selected thread again on your phone.")
                .font(.caption).foregroundStyle(.secondary)
            if snapshot.limited || snapshot.sms != "OK" || snapshot.mms != "OK" {
                Text("Coverage is limited. SMS: \(snapshot.sms); MMS: \(snapshot.mms). \(snapshot.limited ? "A row or size limit was reached." : "A provider could not be read.")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if snapshot.messages.isEmpty { Text("No provider rows in this snapshot.") }
            ForEach(snapshot.messages) { row in
                HStack {
                    if row.direction == "SENT" { Spacer(minLength: 24) }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.text.isEmpty ? AttributedString("[No text exposed]") : PhoneConversationSampleView.linkedText(row.text))
                            .textSelection(.enabled)
                        HStack {
                            Text(row.direction == "SENT" ? "Sent" : row.direction == "RECEIVED" ? "Received" : "Draft or other provider row")
                            if row.timestampMS > 0 {
                                Text(Date(timeIntervalSince1970: Double(row.timestampMS) / 1000).formatted(date: .abbreviated, time: .shortened))
                            } else { Text("Time unavailable") }
                        }.font(.caption).foregroundStyle(.secondary)
                        if row.truncated { Text("Text shortened").font(.caption).foregroundStyle(.secondary) }
                        if row.attachmentsOmitted > 0 || !row.partsComplete {
                            Text("Attachments or message parts are not included.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(12).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: 640, alignment: row.direction == "SENT" ? .trailing : .leading)
                    if row.direction != "SENT" { Spacer(minLength: 0) }
                }
            }
        }
    }
}
