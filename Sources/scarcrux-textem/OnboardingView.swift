import SwiftUI

// First-run sign-in guidance. Google's new account-based pairing offers a
// passkey option that CANNOT work inside an embedded web view (an Apple
// platform limitation for sites we don't own). Steering users to
// password + a non-passkey 2-step avoids a dead-end most people would hit.
struct OnboardingView: View {
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to Textem")
                .font(.title).bold()
            Text("Textem signs you into Google Messages inside the app. One thing matters for a smooth sign-in:")
                .foregroundStyle(.secondary)

            Label {
                Text("Don't use a **passkey** — it can't work inside an app like this. Choose **“Enter your password”** instead.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .padding(12)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            // Sequence follows Google's own pairing steps (support.google.com/
            // messages/answer/7611075, verified 2026-10-13): the phone path is
            // the account menu → Device pairing; the old "Switch to Google
            // Account pairing" toggle no longer exists and QR pairing is gone in
            // the US.
            VStack(alignment: .leading, spacing: 10) {
                step(1, "On your phone, open Google Messages and tap your account menu (top right) → Device pairing.")
                step(2, "Here, sign in with the same Google account and choose “Enter your password.”")
                step(3, "For the second step, pick a non-passkey option: a Google prompt (“Tap Yes”), an SMS/email code, or an authenticator.")
                step(4, "Your phone shows three emoji. Tap the one that matches what Textem shows.")
            }

            Text("Google allows one active computer at a time. Opening Messages for web in a browser makes it the active one and disconnects Textem — reload Textem (⇧⌘R) to switch back.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Got it — Sign in") { onDone() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.callout).bold()
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.2), in: Circle())
            Text(text)
        }
    }
}
