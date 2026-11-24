import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, cards, sound, shortcuts, advanced, about
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .cards: "Cards"
        case .sound: "Sound & haptics"
        case .shortcuts: "Shortcuts"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .cards: "rectangle.on.rectangle.angled.fill"
        case .sound: "speaker.wave.2.fill"
        case .shortcuts: "command"
        case .advanced: "slider.horizontal.3"
        case .about: "info.circle.fill"
        }
    }
}

final class SettingsSelection: ObservableObject {
    static let shared = SettingsSelection()
    @Published var pane: SettingsPane? = .general
}

/// Translucent window: a sidebar with the app's icon and the panes, and grouped cards on the right.
struct SettingsView: View {
    @ObservedObject private var selection = SettingsSelection.shared

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 184)
            Rectangle().fill(.primary.opacity(0.08)).frame(width: 1)
            detail
        }
        .frame(minWidth: 600, minHeight: 440)
        .background(VisualEffect(material: .underWindowBackground).ignoresSafeArea())
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 3) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                Text(verbatim: "Hovr")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text(verbatim: "v\(version)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 40)
            .padding(.bottom, 18)

            VStack(spacing: 2) {
                ForEach(SettingsPane.allCases) { pane in
                    SidebarItem(pane: pane, selected: (selection.pane ?? .general) == pane) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection.pane = pane }
                    }
                }
            }
            .padding(.horizontal, 10)
            Spacer()
        }
        .background(VisualEffect(material: .sidebar).ignoresSafeArea())
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(selection.pane?.title ?? "General")
                    .font(.system(size: 15, weight: .bold))
                    .padding(.top, 14)
                Group {
                    switch selection.pane ?? .general {
                    case .general: GeneralPane()
                    case .cards: CardsPane()
                    case .sound: SoundPane()
                    case .shortcuts: ShortcutsPane()
                    case .advanced: AdvancedPane()
                    case .about: AboutPane()
                    }
                }
                .transition(.opacity)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SidebarItem: View {
    let pane: SettingsPane
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    @Namespace private var ns

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : .secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(selected ? Color.accentColor : .primary.opacity(0.07)))
                Text(pane.title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .foregroundStyle(selected ? .primary : .secondary)
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(.primary.opacity(selected ? 0.1 : (hovering ? 0.05 : 0)))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

// MARK: - Building blocks

struct SettingsGroup<Content: View>: View {
    var header: LocalizedStringKey? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header {
                Text(header)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.leading, 2)
                    .padding(.top, 4)
            }
            VStack(spacing: 0) { content }
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.06)))
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    var divider = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12.5, weight: .medium))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                trailing
            }
            .padding(.vertical, 8)
            if divider { Rectangle().fill(.primary.opacity(0.07)).frame(height: 1) }
        }
    }
}

struct ToggleRow: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    @Binding var isOn: Bool
    var divider = true

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle, divider: divider) {
            Toggle("", isOn: $isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
    }
}

/// Image / Text chooser in the mode colours, matching the selection screen.
struct ModePicker: View {
    @Binding var mode: CaptureMode

    var body: some View {
        HStack(spacing: 4) {
            ForEach(CaptureMode.allCases) { m in
                let on = m == mode
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { mode = m }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: m == .image ? "photo" : "textformat")
                            .font(.system(size: 9, weight: .bold))
                        Text(m.title).font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(on ? Color.white : .secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Capsule().fill(on ? Color(nsColor: m.color) : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(.primary.opacity(0.07)))
    }
}

/// Stepped slider: 3D · 7D · 14D · 30D · Never.
struct RecentsSlider: View {
    @Binding var days: Int
    private let choices = AppSettings.historyChoices

    private var index: Binding<Double> {
        Binding(get: { Double(choices.firstIndex(of: days) ?? 1) },
                set: { days = choices[min(max(Int($0.rounded()), 0), choices.count - 1)] })
    }

    var body: some View {
        VStack(spacing: 4) {
            Slider(value: index, in: 0...Double(choices.count - 1), step: 1)
                .controlSize(.small)
            HStack {
                ForEach(Array(choices.enumerated()), id: \.offset) { i, d in
                    Text(d == 0 ? String(localized: "Never") : "\(d)D")
                        .font(.system(size: 10, weight: d == days ? .bold : .medium))
                        .foregroundStyle(d == days ? .primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: i == 0 ? .leading : (i == choices.count - 1 ? .trailing : .center))
                }
            }
        }
        .frame(width: 200)
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

// MARK: - Panes

struct GeneralPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsGroup {
                SettingsRow(title: "Start capture with", subtitle: "Tab switches mode while selecting.") {
                    ModePicker(mode: $settings.startMode)
                }
                ToggleRow(title: "Hide cards during capture", subtitle: "Open cards stay out of the frozen screen and new captures.",
                          isOn: $settings.hideCardsDuringCapture)
                ToggleRow(title: "Open at login", isOn: $settings.launchAtLogin)
                ToggleRow(title: "Reopen cards when Hovr opens", isOn: $settings.restoreCards, divider: false)
            }

            SettingsGroup(header: "App") {
                SettingsRow(title: "Language", divider: settings.language == settings.launchedLanguage) {
                    Picker("", selection: $settings.language) {
                        ForEach(AppLanguage.allCases) { Text(verbatim: $0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if settings.language != settings.launchedLanguage {
                    SettingsRow(title: "Hovr needs to relaunch to change the language.") {
                        Button("Relaunch") { AppDelegate.relaunch() }
                    }
                }
                ToggleRow(title: "Check for updates automatically", subtitle: "Once a week.", isOn: $settings.autoUpdate, divider: false)
            }
        }
    }
}

struct AdvancedPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var history = History.shared
    @State private var screenAllowed = CGPreflightScreenCaptureAccess()
    @State private var inputAllowed = CGPreflightListenEventAccess()
    @State private var size: Int64 = 0
    @State private var confirmClear = false
    @State private var confirmReset = false

    private var keepNote: String {
        settings.historyDays == 0
            ? String(localized: "Captures stay until you delete them.")
            : String(localized: "Captures are deleted after \(settings.historyDays) days. Cards on screen are always kept.")
    }

    private var folderPath: String {
        (history.folder.path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsGroup(header: "Permissions") {
                SettingsRow(title: "Input Monitoring", subtitle: "For pinch to zoom on cards while you work in another app. Hovr only listens to trackpad gestures.") {
                    if inputAllowed {
                        Label("Granted", systemImage: "checkmark")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(.green.opacity(0.15)))
                    } else {
                        Button("Grant Access") {
                            CGRequestListenEventAccess()
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                SettingsRow(title: "Screen Recording", subtitle: "To capture anything on your screen.", divider: false) {
                    if screenAllowed {
                        Label("Granted", systemImage: "checkmark")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(.green.opacity(0.15)))
                    } else {
                        Button("Grant Access") {
                            CGRequestScreenCaptureAccess()
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            Text("Hovr doesn't track what you do. Captures stay on your Mac.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)

            SettingsGroup(header: "Storage") {
                SettingsRow(title: "Captures folder", subtitle: "\(folderPath) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))") {
                    HStack(spacing: 8) {
                        Button("Change…") { chooseFolder() }
                        Button("Show in Finder") { NSWorkspace.shared.open(history.folder) }
                    }
                }
                SettingsRow(title: "Keep captures") {
                    RecentsSlider(days: $settings.historyDays)
                }
                Text(keepNote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)
                Rectangle().fill(.primary.opacity(0.07)).frame(height: 1)
                SettingsRow(title: "Recents", subtitle: "Your recent images and text, to pin or copy again.") {
                    Button("Open Recents") { (NSApp.delegate as? AppDelegate)?.showHistory() }
                }
                SettingsRow(title: "Clear storage", subtitle: "Deletes the captures in Recents. Cards on screen stay.", divider: false) {
                    Button("Clear", role: .destructive) { confirmClear = true }
                        .foregroundStyle(.red)
                }
            }

            SettingsGroup {
                SettingsRow(title: "Reset all settings", subtitle: "Every setting back to its default. Cards and captures stay.", divider: false) {
                    Button("Reset to Default", role: .destructive) { confirmReset = true }
                        .foregroundStyle(.red)
                }
            }
        }
        .onAppear { size = history.storageSize() }
        .onReceive(history.$entries) { _ in size = history.storageSize() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screenAllowed = CGPreflightScreenCaptureAccess()
            inputAllowed = CGPreflightListenEventAccess()
            if inputAllowed { CardManager.shared.startGestureTap() }
        }
        .confirmationDialog("Delete all captures?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { history.clear() }
        } message: {
            Text("Pinned cards stay open until you close them.")
        }
        .confirmationDialog("Reset all settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { settings.resetToDefaults() }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = history.folder.deletingLastPathComponent()
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Hovr moves your captures to the folder you choose and saves new ones there.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        history.moveFolder(to: url)
        size = history.storageSize()
    }
}

struct CardsPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsGroup {
                SettingsRow(title: "Default color", subtitle: "For new text cards.") {
                    Picker("", selection: $settings.noteColorRandom) {
                        Text("Fixed color").tag(false)
                        Text("Random").tag(true)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                NoteColorPreview(hex: settings.noteColor, random: settings.noteColorRandom) { settings.noteColor = $0 }
                    .padding(.bottom, 10)
                Rectangle().fill(.primary.opacity(0.07)).frame(height: 1)
                SettingsRow(title: "Throw intensity", subtitle: "How hard a flick must be to throw a card.", divider: false) {
                    ThrowSlider(value: $settings.throwIntensity)
                }
            }

            SettingsGroup(header: "Image cards") {
                ToggleRow(title: "Pin the image on screen", subtitle: "Image captures float above every window, right where you selected them.",
                          isOn: $settings.pinImage)
                ToggleRow(title: "Copy the image to the clipboard", isOn: $settings.copyImage, divider: false)
            }

            SettingsGroup(header: "Multiple displays") {
                ToggleRow(title: "Use Hovr on multiple displays", subtitle: "Capture on every display at once. When off, only the display with the pointer.",
                          isOn: $settings.multipleDisplays)
                SettingsRow(title: "When a display is disconnected",
                            subtitle: settings.displayDisconnect == 0
                                ? "Cards move to the main display as they were: docked cards stay docked, open cards stay open."
                                : "Cards move to the middle of the main display, open.", divider: false) {
                    Picker("", selection: $settings.displayDisconnect) {
                        Text("Move as they are").tag(0)
                        Text("Bring back open").tag(1)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SettingsGroup(header: "Interaction") {
                ToggleRow(title: "Double-click to edit", subtitle: "Double-click a text card to edit it. When off, click once to select a card and again to edit.",
                          isOn: $settings.doubleClickToEdit)
                ToggleRow(title: "Two-finger card movement", subtitle: "Drag a card with two fingers on the trackpad and flick to throw it. Text that scrolls still scrolls.",
                          isOn: $settings.scrollMovesCard)
                ToggleRow(title: "Cards can hang past the screen edge", subtitle: "A card left partly off the screen stays there. When off, it slides back onto the screen.",
                          isOn: $settings.hangPastEdge, divider: false)
            }

            SettingsGroup(header: "Gestures") {
                GestureRow(symbol: "rectangle.righthalf.inset.filled.arrow.right", title: "Drag or throw to a screen edge", detail: "Dock · click to bring back")
                GestureRow(symbol: "arrow.up.left.and.arrow.down.right", title: "Drag an edge", detail: "Resize")
                GestureRow(symbol: "plus.magnifyingglass", title: "Pinch or ⌘ + scroll", detail: "Zoom")
                GestureRow(symbol: "circle.lefthalf.filled", title: "⌥ + scroll", detail: "Opacity")
                GestureRow(symbol: "arrow.uturn.backward", title: "Double-click an image", detail: "Original size", divider: false)
            }
        }
    }
}

/// A sample text card in the chosen colour, next to the colour swatches.
private struct NoteColorPreview: View {
    let hex: String
    let random: Bool
    let pick: (String) -> Void
    private let columns = Array(repeating: GridItem(.fixed(22), spacing: 8), count: 6)

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.primary.opacity(0.04))
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 9, height: 9)
                        Spacer()
                        Image(systemName: "checklist").font(.system(size: 9, weight: .semibold))
                        Image(systemName: "ellipsis").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(textColor.opacity(0.6))
                    Text("The quick brown fox jumps over the lazy dog")
                        .font(.system(size: 11.5))
                        .foregroundStyle(textColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(width: 170, height: 92)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(random ? AnyShapeStyle(randomFill) : AnyShapeStyle(Color(nsColor: NoteColor.color(hex)))))
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            }
            .frame(maxWidth: .infinity, minHeight: 118)
            VStack(spacing: 8) {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(NoteColor.palette, id: \.self) { h in
                        let on = !random && h == hex
                        Circle()
                            .fill(Color(nsColor: NoteColor.color(h)))
                            .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                            .overlay(Circle().strokeBorder(Color.primary, lineWidth: on ? 2 : 0).padding(-3))
                            .frame(width: 20, height: 20)
                            .contentShape(Circle())
                            .onTapGesture { pick(h) }
                    }
                    Circle()
                        .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                        .overlay(Circle().fill(.background).padding(5))
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                        .onTapGesture { ColorPick.shared.open(initial: NoteColor.color(hex)) { pick(NoteColor.hex($0)) } }
                }
                Text(random ? String(localized: "Random") : NoteColor.name(hex))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .opacity(random ? 0.45 : 1)
            .disabled(random)
        }
    }

    private var textColor: Color { random ? .black : (NoteColor.isDark(NoteColor.color(hex)) ? .white : .black) }
    private var randomFill: LinearGradient {
        LinearGradient(colors: NoteColor.palette.prefix(6).map { Color(nsColor: NoteColor.color($0)) }, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Easy · Normal · Firm.
private struct ThrowSlider: View {
    @Binding var value: Int
    var body: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }), in: 0...2, step: 1)
                .controlSize(.small)
            HStack {
                Text("Easy").frame(maxWidth: .infinity, alignment: .leading)
                Text("Normal").frame(maxWidth: .infinity)
                Text("Firm").frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .frame(width: 180)
    }
}

private struct GestureRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    var divider = true

    var body: some View {
        SettingsRow(title: title, divider: divider) {
            HStack(spacing: 8) {
                Text(detail).foregroundStyle(.secondary).font(.system(size: 11.5))
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
            }
        }
    }
}

struct SoundPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsGroup {
            ToggleRow(title: "Sound effects", subtitle: "The shutter as you capture, the whoosh as a card flies.", isOn: $settings.soundEffects)
            ToggleRow(title: "Shutter sound on capture", isOn: $settings.shutterSound)
                .disabled(!settings.soundEffects).opacity(settings.soundEffects ? 1 : 0.5)
            ToggleRow(title: "Whoosh when a card is thrown", isOn: $settings.whooshSound)
                .disabled(!settings.soundEffects).opacity(settings.soundEffects ? 1 : 0.5)
            ToggleRow(title: "Haptic feedback", subtitle: "A light tap on the trackpad when a card docks or the capture mode changes.",
                      isOn: $settings.haptics, divider: false)
        }
    }
}

struct ShortcutsPane: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsGroup(header: "Global") {
                ForEach(Array(HotkeyAction.allCases.enumerated()), id: \.element) { i, action in
                    SettingsRow(title: LocalizedStringKey(action.title), divider: i < HotkeyAction.allCases.count - 1) {
                        ShortcutRecorder(shortcut: Binding(get: { settings.shortcuts[action] },
                                                           set: { settings.shortcuts[action] = $0 }),
                                         conflict: settings.takenShortcuts.contains(action) ? "Another app already uses this shortcut" : nil)
                    }
                }
            }
            SettingsGroup(header: "Cards") {
                KeyRow(keys: ["⌘", "0–9"], title: "Opacity", subtitle: "Set opacity from 10 to 90% with keys 1–9, and 100% with 0")
                KeyRow(keys: ["⌘L"], title: "Lock or unlock")
                KeyRow(keys: ["⌘W"], title: "Close card")
                KeyRow(keys: ["Return"], title: "Edit text", divider: false)
            }
            SettingsGroup(header: "Editing text") {
                KeyRow(keys: ["⌘B"], title: "Bold")
                KeyRow(keys: ["⌘I"], title: "Italic")
                KeyRow(keys: ["⌘U"], title: "Underline")
                KeyRow(keys: ["⇧⌘X"], title: "Strikethrough")
                KeyRow(keys: ["⌘", "+ −"], title: "Text size", subtitle: "Larger with +, smaller with −")
                KeyRow(keys: ["⇧⌘V"], title: "Paste as plain text")
                KeyRow(keys: ["Esc"], title: "Finish editing", divider: false)
            }
            SettingsGroup(header: "Capturing") {
                KeyRow(keys: ["Tab"], title: "Text or image")
                KeyRow(keys: ["Space"], title: "A whole window")
                KeyRow(keys: ["⇧"], title: "Square selection")
                KeyRow(keys: ["⌥"], title: "Free-form selection", subtitle: "Hold and click the corners of what to keep")
                KeyRow(keys: ["Esc"], title: "Cancel", divider: false)
            }
        }
    }
}

/// A shortcut shown as one or two key caps.
private struct KeyRow: View {
    let keys: [String]
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    var divider = true

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle, divider: divider) {
            HStack(spacing: 0) {
                ForEach(Array(keys.enumerated()), id: \.offset) { i, k in
                    if i > 0 { Rectangle().fill(.primary.opacity(0.12)).frame(width: 1, height: 16) }
                    Text(verbatim: k)
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(minWidth: keys.count > 1 ? 40 : 84)
                        .padding(.vertical, 4)
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.08)))
        }
    }
}

struct AboutPane: View {
    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        SettingsGroup {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                Text(verbatim: "Hovr").font(.title2.weight(.semibold))
                Text("Version \(version)").foregroundStyle(.secondary)
                Text("Capture anything on screen and keep it floating above every window as a visual reference, or copy its text.")
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                VStack(spacing: 2) {
                    Text("Developed by").font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: "Lucas Haliax").font(.system(size: 15, weight: .semibold))
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(Capsule().fill(.primary.opacity(0.07)))
                UpdateSection()
            }
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
    }
}

struct UpdateSection: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(spacing: 10) {
            switch updater.state {
            case .idle:
                Button("Check for Updates") { Task { await updater.check() } }
            case .checking:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking for updates…") }
            case .upToDate:
                Label("Hovr is up to date", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Check Again") { Task { await updater.check() } }
            case .available(let release):
                Text("Version \(release.version) is available").font(.headline)
                if !release.notes.isEmpty {
                    ScrollView {
                        Text(LocalizedStringKey(Self.plain(release.notes)))
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: 420, maxHeight: 120)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
                }
                HStack {
                    Link("Release Notes", destination: release.pageURL)
                    Button("Install and Relaunch") { updater.install(release) }
                        .keyboardShortcut(.defaultAction)
                }
            case .downloading:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Downloading…") }
            case .installing:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Installing…") }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Button("Try Again") { Task { await updater.check() } }
            }
        }
        .padding(.top, 4)
    }

    /// Release notes are Markdown; keep inline styling but drop headings and code fences.
    static func plain(_ markdown: String) -> String {
        markdown
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("```") }
            .map { $0.hasPrefix("#") ? $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) : $0 }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
