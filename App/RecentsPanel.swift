import AppKit
import SwiftUI

/// Recents: a dark gradient that slides in from the right edge of the screen, with the captures and notes
/// grouped by day. Click one to pin it again; right-click for more. Esc, a click outside or ⌃⌥H closes it.
@MainActor
final class RecentsPanelController {
    static let shared = RecentsPanelController()
    private var panel: RecentsWindow?
    private var monitors: [Any] = []
    private let model = RecentsModel()

    var isOpen: Bool { panel?.isVisible == true }

    func toggle() { isOpen ? close() : open() }

    func open() {
        History.shared.prune()
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let width: CGFloat = 430
        // The whole height of the screen (under the menu bar and behind the Dock), so the fade never stops short.
        let sf = screen.frame, vf = screen.visibleFrame
        let frame = NSRect(x: sf.maxX - width, y: sf.minY, width: width, height: sf.height)
        model.topInset = sf.maxY - vf.maxY
        model.bottomInset = vf.minY - sf.minY
        let p = panel ?? RecentsWindow(model: model, close: { [weak self] in self?.close() })
        panel = p
        p.setFrame(frame, display: true)
        p.alphaValue = 0
        model.shown = false
        p.orderFrontRegardless()
        p.makeKey()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; p.animator().alphaValue = 1 }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { model.shown = true }
        installMonitors()
    }

    func close() {
        removeMonitors()
        guard let p = panel, p.isVisible else { return }
        withAnimation(.easeIn(duration: 0.16)) { model.shown = false }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; p.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { p.orderOut(nil) }
        }
    }

    private func installMonitors() {
        removeMonitors()
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(m) }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }
}

final class RecentsModel: ObservableObject {
    @Published var shown = false
    @Published var topInset: CGFloat = 0
    @Published var bottomInset: CGFloat = 0
}

final class RecentsWindow: NSPanel {
    private let close: () -> Void

    init(model: RecentsModel, close: @escaping () -> Void) {
        self.close = close
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        // A blur that grows towards the edge (masked visual effect), under the darkening gradient and the items.
        let container = NSView()
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = Self.fadeMask
        blur.autoresizingMask = [.width, .height]
        let host = NSHostingView(rootView: RecentsView(model: model, close: close))
        host.autoresizingMask = [.width, .height]
        container.addSubview(blur)
        container.addSubview(host)
        contentView = container
    }

    /// Clear on the left, solid on the right, with an eased curve (stretched to the window).
    private static let fadeMask: NSImage = {
        let w = 256
        let img = NSImage(size: NSSize(width: w, height: 1), flipped: false) { r in
            for x in 0..<w {
                let t = CGFloat(x) / CGFloat(w - 1)
                let eased = t * t * (3 - 2 * t)            // smoothstep
                NSColor(white: 0, alpha: min(1, eased * 1.15)).setFill()
                NSRect(x: CGFloat(x), y: 0, width: 1, height: 1).fill()
            }
            return true
        }
        img.resizingMode = .stretch
        return img
    }()

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { close() } else { super.keyDown(with: event) } }
}

// MARK: - Content

struct RecentsView: View {
    @ObservedObject var model: RecentsModel
    @ObservedObject private var history = History.shared
    let close: () -> Void

    private let columns = [GridItem(.fixed(104), spacing: 10), GridItem(.fixed(104), spacing: 10)]

    private var groups: [(day: Date, items: [HistoryEntry])] {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: history.entries) { cal.startOfDay(for: $0.date) }
        return byDay.keys.sorted(by: >).map { ($0, byDay[$0]!.sorted { $0.date > $1.date }) }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        return f
    }()

    private static let shortDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMMM")
        return f
    }()

    private func title(for day: Date) -> String {
        let cal = Calendar.current
        let date = Self.dayFormatter.string(from: day)
        let short = Self.shortDayFormatter.string(from: day)
        if cal.isDateInToday(day) { return String(localized: "Today, \(short)") }
        if cal.isDateInYesterday(day) { return String(localized: "Yesterday, \(short)") }
        return date.prefix(1).capitalized + date.dropFirst()
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            // A long, eased fade from clear to dark, so there is no visible edge.
            LinearGradient(stops: [
                .init(color: .black.opacity(0), location: 0),
                .init(color: .black.opacity(0.03), location: 0.2),
                .init(color: .black.opacity(0.1), location: 0.35),
                .init(color: .black.opacity(0.2), location: 0.5),
                .init(color: .black.opacity(0.3), location: 0.65),
                .init(color: .black.opacity(0.38), location: 0.8),
                .init(color: .black.opacity(0.42), location: 1),
            ], startPoint: .leading, endPoint: .trailing)
            .ignoresSafeArea()
            .opacity(model.shown ? 1 : 0)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Recents").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    let active = CardManager.shared.cards.count
                    if active > 0 {
                        Text("\(active) active").font(.system(size: 13)).foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer()
                }
                .padding(.top, 12 + model.topInset)

                if history.entries.isEmpty {
                    Spacer()
                    Text("Your captures show up here.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(groups, id: \.day) { group in
                                Text(title(for: group.day))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.4))
                                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                                    ForEach(group.items) { RecentTile(entry: $0, close: close) }
                                }
                            }
                        }
                        .padding(.bottom, 16 + model.bottomInset)
                    }
                    .modifier(NoScrollEdgeEffect())
                }
            }
            .frame(width: 218)
            .padding(.trailing, 14)
            .offset(x: model.shown ? 0 : 60)
            .opacity(model.shown ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}

private struct RecentTile: View {
    let entry: HistoryEntry
    let close: () -> Void
    @State private var hover = false
    /// A small, steady tilt per item (from its id), like photos laid on a desk.
    private var tilt: Double { Double(Int(entry.id.uuid.0) % 5 - 2) * 0.6 }

    var body: some View {
        ZStack {
            if entry.note || (entry.isTextCapture && !(entry.text ?? "").isEmpty) {
                textTile
            } else if let img = History.shared.thumbnail(for: entry.id, maxPixels: 260) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 104, height: 104)
                    .clipped()
            } else {
                Color.white.opacity(0.08)
            }
        }
        .frame(width: 104, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(hover ? 0.7 : 0.12), lineWidth: hover ? 2 : 1))
        .overlay(alignment: .topTrailing) {
            if CardManager.shared.isOpen(entry.id) {
                Circle().fill(Color.green).frame(width: 7, height: 7).padding(7)
            }
        }
        .rotationEffect(.degrees(hover ? 0 : tilt))
        .scaleEffect(hover ? 1.04 : 1)
        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .onTapGesture { open() }
        .help(entry.note ? Text("Open note") : (entry.isTextCapture ? Text("Copy text") : Text("Pin on screen")))
        .contextMenu {
            if entry.isTextCapture {
                Button("Copy Text") { copyText() }
            } else if entry.note {
                Button("Open note") { open() }
                Button("Copy Text") { copyText() }
            } else {
                Button("Pin on Screen") { open() }
                Button("Copy Image") {
                    if let img = History.shared.image(for: entry.id) { Pasteboard.copy(image: img, scale: entry.scale) }
                }
                Button("Copy Text") { copyText() }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([History.shared.fileURL(entry.id)])
            }
            Divider()
            Button("Delete", role: .destructive) {
                CardManager.shared.card(entry.id)?.closeCard()
                History.shared.delete(entry.id)
            }
        }
    }

    private var textTile: some View {
        let bg = entry.note ? NoteColor.color(entry.noteColor) : .white
        let dark = NoteColor.isDark(bg)
        return ZStack(alignment: .topLeading) {
            Color(nsColor: bg)
            Text(entry.text?.isEmpty == false ? entry.text! : String(localized: "Empty note"))
                .font(.system(size: 9.5))
                .foregroundStyle(dark ? Color.white : Color.black.opacity(0.8))
                .lineLimit(9)
                .padding(8)
        }
    }

    private func open() {
        if entry.isTextCapture { copyText(); return }
        close()
        CardManager.shared.pin(entry.id)
    }

    private func copyText() {
        Task { @MainActor in
            let t = await History.shared.text(for: entry.id) ?? ""
            if t.isEmpty {
                HUD.shared.show(String(localized: "No text found"), symbol: "text.magnifyingglass")
            } else {
                Pasteboard.copy(text: t)
                HUD.shared.show(String(localized: "Text copied"), symbol: "doc.on.clipboard")
            }
        }
    }
}

/// No blurred band behind scrolling content (macOS 26 adds one by default).
private struct NoScrollEdgeEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .all)
        } else {
            content
        }
    }
}
