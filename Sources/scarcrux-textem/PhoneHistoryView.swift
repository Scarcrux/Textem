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
            ForEach(snapshot.messages) { PhoneHistoryMessageView(row: $0) }
            Text("Some messages and pictures may be missing. To update this copy, save the conversation again in the Android companion.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PhoneHistoryMessageView: View {
    let row: PhoneHistorySnapshot.Message
    var inTimeline = false

    private var sent: Bool { row.direction == "SENT" }
    private var direction: String {
        if sent { return "Sent" }
        return row.direction == "RECEIVED" ? "Received" : "Sent or received status unavailable"
    }
    private var time: String {
        guard row.timestampMS > 0 else { return "Time unavailable" }
        let date = Date(timeIntervalSince1970: Double(row.timestampMS) / 1000)
        return date.formatted(date: inTimeline ? .omitted : .abbreviated, time: .shortened)
    }

    var body: some View {
        let blueBubble = sent && inTimeline
        HStack {
            if sent { Spacer(minLength: 24) }
            VStack(alignment: .leading, spacing: 6) {
                Text(row.text.isEmpty ? AttributedString("[No saved text]") : PhoneConversationSampleView.linkedText(row.text))
                    .tint(blueBubble ? .white : .accentColor)
                    .textSelection(.enabled)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if !inTimeline { Text(direction) }
                        Text(time)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(direction), \(time)")
                    if row.truncated { Text("Text shortened") }
                    if row.attachmentsOmitted > 0 || !row.partsComplete {
                        Text("Some pictures or attachments weren’t saved.")
                    }
                }
                .font(.caption)
                .foregroundStyle(blueBubble ? Color.white.opacity(0.92) : Color.secondary)
            }
            .foregroundStyle(blueBubble ? Color.white : Color.primary)
            .padding(12)
            .background(blueBubble ? Color(red: 0.12, green: 0.34, blue: 0.71) : Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: 640, alignment: sent ? .trailing : .leading)
            if !sent { Spacer(minLength: 0) }
        }
    }
}
