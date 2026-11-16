import SwiftUI

// Shared title block for the phone-companion panels, so the image library and
// the notification preview read as one family: symbol, title, one-line scope.
struct PhonePanelHeader: View {
    let symbol: String
    let title: String
    let subtitle: String
    var onClose: (() -> Void)? = nil
    var closeLabel = "Close"
    var trailingActions: AnyView? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if let trailingActions { trailingActions }
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(closeLabel)
            }
        }
    }
}
