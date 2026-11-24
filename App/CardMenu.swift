import AppKit
import SwiftUI

/// The "⋯" menu of a card: copy, colour (notes), opacity, lock, delete. A small glass panel under the button.
@MainActor
final class CardMenuController {
    static let shared = CardMenuController()
    private var panel: GlassPanel?
    private var monitors: [Any] = []
    private weak var card: CardWindow?

    func show(for card: CardWindow, below anchor: NSRect) {
        close()
        self.card = card
        let model = CardMenuModel(card: card)
        let view = CardMenuView(model: model, close: { [weak self] in self?.close() })
        let p = GlassPanel(content: AnyView(view))
        let size = p.hosting.fittingSize
        let vf = (NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main)?.visibleFrame ?? .zero
        var x = anchor.maxX - 26
        if x + size.width > vf.maxX - 6 { x = anchor.maxX - size.width }
        var y = anchor.minY - 4 - size.height
        if y < vf.minY + 6 { y = anchor.maxY + 4 }
        p.setFrame(NSRect(x: max(vf.minX + 6, x), y: y, width: size.width, height: size.height).integral, display: true)
        p.onEscape = { [weak self] in self?.close() }
        p.displayIfNeeded()
        // Grows out of the ⋯ button.
        let f = p.frame
        anchorPoint = CGPoint(x: min(max((anchor.midX - f.minX) / f.width, 0), 1), y: anchor.midY > f.midY ? 1 : 0)
        PopAnimation.show(p.body, anchor: anchorPoint)
        p.orderFrontRegardless()
        p.makeKey()
        p.invalidateShadow()
        panel = p
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in
            let clicked = e.window.map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                if clicked != ObjectIdentifier(panel) && clicked != ObjectIdentifier(NSColorPanel.shared) { self.close() }
            }
            return e
        }) { monitors.append(m) }
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        guard let p = panel else { return }
        panel = nil
        PopAnimation.hide(p.body, anchor: anchorPoint) { p.orderOut(nil) }
    }

    private var anchorPoint = CGPoint(x: 0, y: 1)
}

@MainActor
final class CardMenuModel: ObservableObject {
    let card: CardWindow
    @Published var opacity: Double { didSet { card.setOpacity(opacity, showValue: false) } }
    @Published var locked: Bool
    init(card: CardWindow) {
        self.card = card
        opacity = card.alphaValue
        locked = card.locked
    }
    var note: NoteCardView? { card.host.subviews.compactMap { $0 as? NoteCardView }.first }
}

/// Glass (macOS 26+) or popover material panel hosting SwiftUI content.
final class GlassPanel: NSPanel {
    let hosting: NSHostingView<AnyView>
    /// Wrapper that carries the open/close animation.
    let body = NSView()
    var onEscape: (() -> Void)?

    init(content: AnyView, cornerRadius: CGFloat = 12) {
        hosting = NSHostingView(rootView: content)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 200), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let container = NSView()
        let bg: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = hosting
            bg = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.state = .active
            effect.blendingMode = .behindWindow
            effect.wantsLayer = true
            effect.layer?.cornerRadius = cornerRadius
            effect.layer?.masksToBounds = true
            hosting.autoresizingMask = [.width, .height]
            effect.addSubview(hosting)
            bg = effect
        }
        bg.autoresizingMask = [.width, .height]
        body.wantsLayer = true
        body.autoresizingMask = [.width, .height]
        body.addSubview(bg)
        container.addSubview(body)
        contentView = container
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) } }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        body.frame = contentView?.bounds ?? .zero
        body.subviews.first?.frame = body.bounds
        hosting.frame = (hosting.superview?.bounds) ?? hosting.frame
    }
}

// MARK: - Content

struct CardMenuView: View {
    @ObservedObject var model: CardMenuModel
    let close: () -> Void

    private var isNote: Bool { model.card.isNote }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if isNote {
                    let count = model.note?.plainText.count ?? 0
                    MenuItemRow(symbol: "doc.on.doc", title: String(localized: "Copy all"),
                                trailing: String(localized: "\(count) characters")) { model.card.copyText(); close() }
                } else {
                    MenuItemRow(symbol: "photo.on.rectangle", title: String(localized: "Copy Image"), trailing: "⌘C") { model.card.copyImage(); close() }
                    MenuItemRow(symbol: "text.viewfinder", title: String(localized: "Copy Text"), trailing: "⇧⌘C") { model.card.copyText(); close() }
                    MenuItemRow(symbol: "square.and.arrow.down", title: String(localized: "Save Image…"), trailing: "⌘S") { close(); model.card.saveImage() }
                }
            }
            .padding(.horizontal, 5)
            .padding(.top, 5)

            divider

            if isNote, let note = model.note {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Background color").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    ColorSwatches(selected: NoteColor.hex(note.background)) { note.setColor($0) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Card opacity").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: "\(Int((model.opacity * 100).rounded()))%")
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.tertiary)
                }
                Slider(value: $model.opacity, in: 0.1...1, step: 0.1).controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            divider

            VStack(spacing: 0) {
                MenuItemRow(symbol: model.locked ? "lock.fill" : "lock", title: model.locked ? String(localized: "Unlock") : String(localized: "Lock"),
                            trailing: "⌘L") {
                    model.card.toggleLock()
                    model.locked = model.card.locked
                }
                if isNote {
                    MenuItemRow(symbol: "trash", title: String(localized: "Delete"), trailing: nil, destructive: true) {
                        close(); model.card.deleteCard()
                    }
                } else {
                    MenuItemRow(symbol: "xmark", title: String(localized: "Close"), trailing: "⌘W", destructive: true) {
                        close(); model.card.closeCard()
                    }
                }
            }
            .padding(.horizontal, 5)
            .padding(.bottom, 5)
        }
        .frame(width: 232)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var divider: some View {
        Rectangle().fill(.primary.opacity(0.1)).frame(height: 1).padding(.vertical, 4)
    }
}

private struct MenuItemRow: View {
    let symbol: String
    let title: String
    let trailing: String?
    var destructive = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                    .foregroundStyle(hover && destructive ? Color.white : .secondary)
                Text(title).font(.system(size: 13))
                    .foregroundStyle(hover && destructive ? Color.white : .primary)
                Spacer()
                if let trailing {
                    Text(verbatim: trailing).font(.system(size: 12))
                        .foregroundStyle(hover && destructive ? Color.white.opacity(0.8) : Color.secondary.opacity(0.7))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hover ? (destructive ? Color.red : Color.primary.opacity(0.09)) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.1)) { hover = h } }
    }
}

/// Six colours per row, the last one opens the system colour picker.
private struct ColorSwatches: View {
    let selected: String
    let pick: (NSColor) -> Void
    @State private var current: String = ""

    private let columns = Array(repeating: GridItem(.fixed(26), spacing: 8), count: 6)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(NoteColor.palette, id: \.self) { hex in
                let on = (current.isEmpty ? selected : current) == hex
                Circle()
                    .fill(Color(nsColor: NoteColor.color(hex)))
                    .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: on ? 2 : 0).padding(-3))
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
                    .onTapGesture {
                        current = hex
                        pick(NoteColor.color(hex))
                    }
            }
            Circle()
                .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                .overlay(Circle().fill(.background).padding(5))
                .frame(width: 22, height: 22)
                .contentShape(Circle())
                .onTapGesture { ColorPick.shared.open(initial: NoteColor.color(selected)) { c in current = NoteColor.hex(c); pick(c) } }
        }
    }
}

/// Bridges NSColorPanel to a closure.
@MainActor
final class ColorPick: NSObject {
    static let shared = ColorPick()
    private var onPick: ((NSColor) -> Void)?

    func open(initial: NSColor, onPick: @escaping (NSColor) -> Void) {
        self.onPick = onPick
        let p = NSColorPanel.shared
        p.showsAlpha = false
        p.color = initial
        p.setTarget(self)
        p.setAction(#selector(changed(_:)))
        p.level = .popUpMenu
        p.orderFrontRegardless()
    }

    @objc private func changed(_ sender: NSColorPanel) { onPick?(sender.color) }
}
