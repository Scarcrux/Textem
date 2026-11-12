import SwiftUI

// Centered "nothing here yet" block for the phone-companion panels: what is
// missing, then the one thing to do about it.
struct PhoneEmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var titleIdentifier: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 6)
                .accessibilityHidden(true)
            Text(title).font(.headline)
                .accessibilityIdentifier(titleIdentifier ?? "")
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
