import SwiftUI

struct CodeShortcutPicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var monitor: Any?
    @State private var recorderWindow: NSWindow?
    @State private var heldModifiers = ""
    @State private var showingHeldModifiers = false
    @State private var rejectedKeys: String?
    @State private var candidate: GlobalHotkey.Shortcut?
    @State private var error: String?
    let save: (GlobalHotkey.Shortcut) -> Bool

    private var displayedKeys: String {
        showingHeldModifiers ? heldModifiers : candidate?.label ?? rejectedKeys ?? "Waiting for keys…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Change Copy Latest Code Shortcut").font(.headline)
            Text("Press a letter or number with two or more modifiers, including Command or Control.")
            Text(displayedKeys)
                .font(.title2.monospaced())
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Shortcut keys")
                .accessibilityValue(displayedKeys)
            if let error {
                Text(error).foregroundStyle(.secondary)
            }
            HStack {
                Button("Restore Default") {
                    showingHeldModifiers = false
                    rejectedKeys = nil
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
                .disabled(candidate == nil || showingHeldModifiers)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(RecorderWindow { window in recorderWindow = window })
        .onAppear {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
                let captured = MainActor.assumeIsolated {
                    guard let window = recorderWindow, window.isKeyWindow,
                          event.window == nil || event.window === window else { return false }
                    if event.type == .flagsChanged {
                        let modifiers = GlobalHotkey.Shortcut.modifierLabel(for: event.modifierFlags)
                        if modifiers.count > heldModifiers.count { showingHeldModifiers = true }
                        heldModifiers = modifiers
                        if modifiers.isEmpty { showingHeldModifiers = false }
                        return false
                    }
                    guard !event.modifierFlags.intersection([.control, .option, .shift, .command]).isEmpty else {
                        return false
                    }
                    showingHeldModifiers = false
                    guard let shortcut = GlobalHotkey.Shortcut.captured(from: event) else {
                        error = "Use a letter or number with at least two modifiers, including Command or Control."
                        candidate = nil
                        let modifiers = GlobalHotkey.Shortcut.modifierLabel(for: event.modifierFlags)
                        let key = event.characters(byApplyingModifiers: [])?.uppercased()
                        let printableKey = key.flatMap { label in
                            label.count == 1 && !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                                ? label : nil
                        }
                        rejectedKeys = modifiers + (printableKey ?? "")
                        return true
                    }
                    rejectedKeys = nil
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
            recorderWindow = nil
        }
    }
}

private struct RecorderWindow: NSViewRepresentable {
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowProbe {
        let view = WindowProbe()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ view: WindowProbe, context: Context) {
        view.onWindowChange = onWindowChange
    }

    final class WindowProbe: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            Task { @MainActor [weak self] in
                guard let self else { return }
                onWindowChange?(window)
            }
        }
    }
}
