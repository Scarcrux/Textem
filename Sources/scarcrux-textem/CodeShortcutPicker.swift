import SwiftUI

struct CodeShortcutPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var monitor: Any?
    @State private var candidate: GlobalHotkey.Shortcut?
    @State private var error: String?
    let save: (GlobalHotkey.Shortcut) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Change Copy Latest Code Shortcut").font(.headline)
            Text("Press a letter or number with two or more modifiers, including Command or Control.")
            if let candidate {
                Text(candidate.label).font(.title2.monospaced())
            }
            if let error {
                Text(error).foregroundStyle(.secondary)
            }
            HStack {
                Button("Restore Default") {
                    candidate = .copyCode
                    error = nil
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard let candidate else { return }
                    if save(candidate) {
                        dismiss()
                    } else {
                        error = "\(candidate.label) is unavailable. Try a different shortcut."
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(candidate == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let captured = MainActor.assumeIsolated {
                    guard let window = event.window, window.isKeyWindow, window.sheetParent != nil,
                          let shortcut = GlobalHotkey.Shortcut.captured(from: event) else { return false }
                    candidate = shortcut
                    error = nil
                    return true
                }
                return captured ? nil : event
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
