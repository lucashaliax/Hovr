import AppKit
import SwiftUI

/// A native-looking shortcut field: click, press the keys, done.
/// ⎋ cancels, ⌫ clears. Global hotkeys are paused while recording.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    var conflict: LocalizedStringKey? = nil

    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 6) {
            if let conflict {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(Text(conflict))
            }
            Button(action: toggleRecording) {
                HStack(spacing: 6) {
                    Text(label)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(recording ? Color.accentColor : (shortcut == nil ? .secondary : .primary))
                        .frame(minWidth: 70)
                    if shortcut != nil && !recording {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .onTapGesture { shortcut = nil }
                            .help(Text("Remove shortcut"))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(recording ? Color.accentColor : Color(nsColor: .separatorColor),
                                      lineWidth: recording ? 1.5 : 0.5)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Record shortcut"))
        }
        .onDisappear(perform: stop)
    }

    private var label: String {
        if recording { return hint ?? String(localized: "Press keys…") }
        return shortcut?.displayString ?? String(localized: "Record shortcut")
    }

    private func toggleRecording() {
        recording ? stop() : start()
    }

    private func start() {
        recording = true
        hint = nil
        HotkeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil // swallow while recording
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { HotkeyCenter.shared.resume() }
        recording = false
        hint = nil
    }

    private func handle(_ event: NSEvent) {
        let candidate = Shortcut(event: event)
        let plain = candidate.modifiers == 0
        if plain && event.keyCode == 53 { stop(); return }                    // ⎋
        if plain && (event.keyCode == 51 || event.keyCode == 117) {           // ⌫ ⌦
            shortcut = nil; stop(); return
        }
        guard candidate.isValidGlobal else {
            hint = String(localized: "Add ⌃, ⌥ or ⌘")
            return
        }
        shortcut = candidate
        stop()
    }
}
