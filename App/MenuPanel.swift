import AppKit
import SwiftUI

/// The menu bar popover: two large capture buttons on top, then Recents, Settings and Quit.
/// Opens with a short spring from the menu bar icon and closes on any click outside or Esc.
@MainActor
final class MenuPanelController {
    static let shared = MenuPanelController()

    private var panel: MenuPanel?
    private var monitors: [Any] = []
    var isOpen: Bool { panel?.isVisible == true }

    var actions = MenuActions()

    func toggle(from button: NSStatusBarButton) {
        isOpen ? close() : open(from: button)
    }

    func open(from button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        button.highlight(true)

        let host = panel.hosting
        host.rootView = MenuContent(actions: actions, close: { [weak self] in self?.close() })
        let size = host.fittingSize
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let vf = screen?.visibleFrame ?? .zero
        var x = anchor.midX - size.width / 2
        x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        let frame = NSRect(x: x, y: anchor.minY - 4 - size.height, width: size.width, height: size.height)
        panel.setFrame(frame.integral, display: true)

        panel.alphaValue = 1
        panel.displayIfNeeded()
        menuAnchor = CGPoint(x: min(max((anchor.midX - frame.minX) / frame.width, 0), 1), y: 1)
        PopAnimation.show(panel.body, anchor: menuAnchor)
        panel.orderFrontRegardless()
        panel.makeKey()
        // The shadow must follow the rounded glass, not the square window.
        panel.invalidateShadow()
        installMonitors()
    }

    func close(animated: Bool = true) {
        guard let panel, panel.isVisible else { return }
        removeMonitors()
        statusButton?.highlight(false)
        guard animated else { panel.orderOut(nil); return }
        PopAnimation.hide(panel.body, anchor: menuAnchor) { panel.orderOut(nil) }
    }

    private var menuAnchor = CGPoint(x: 0.5, y: 1)

    weak var statusButton: NSStatusBarButton?

    private func makePanel() -> MenuPanel {
        let p = MenuPanel()
        p.onEscape = { [weak self] in self?.close() }
        return p
    }

    private func installMonitors() {
        removeMonitors()
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(m) }
        // Clicks in our own windows (cards, Settings) close it too, but not clicks in the panel or on the icon.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in
            let clicked = e.window.map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self else { return }
                let mine = [self.panel, self.statusButton?.window].compactMap { $0 }.map(ObjectIdentifier.init)
                if let clicked, mine.contains(clicked) { return }
                self.close()
            }
            return e
        }) { monitors.append(m) }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }
}

struct MenuActions {
    var captureImage: () -> Void = {}
    var captureText: () -> Void = {}
    var recents: () -> Void = {}
    var settings: () -> Void = {}
    var closeAllCards: () -> Void = {}
    var quit: () -> Void = {}
}

final class MenuPanel: NSPanel {
    let hosting = NSHostingView(rootView: MenuContent(actions: MenuActions(), close: {}))
    let container = NSView()
    /// Wrapper that carries the open/close animation (the content view's own layer is left alone).
    let body = NSView()
    var onEscape: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        container.wantsLayer = true
        let background: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 12
            glass.contentView = hosting
            background = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.state = .active
            effect.blendingMode = .behindWindow
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 12
            effect.layer?.masksToBounds = true
            hosting.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: effect.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
            background = effect
        }
        background.autoresizingMask = [.width, .height]
        body.wantsLayer = true
        body.autoresizingMask = [.width, .height]
        body.addSubview(background)
        container.addSubview(body)
        contentView = container
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

// MARK: - SwiftUI content

struct MenuContent: View {
    let actions: MenuActions
    let close: () -> Void
    @ObservedObject private var settings = AppSettings.shared

    private var cards: Int { CardManager.shared.cards.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                BigButton(symbol: "viewfinder", title: String(localized: "Capture"),
                          shortcut: settings.shortcut?.displayString, tint: CaptureMode.image.color) {
                    run(actions.captureImage)
                }
                Rectangle().fill(.primary.opacity(0.12)).frame(width: 1).padding(.vertical, 8)
                BigButton(symbol: "text.viewfinder", title: String(localized: "Capture Text"),
                          shortcut: nil, tint: CaptureMode.text.color) {
                    run(actions.captureText)
                }
            }
            .padding(5)

            separator

            MenuToggleRow(symbol: "macwindow", title: String(localized: "Window click"),
                          isOn: $settings.clickToCaptureWindow)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)

            separator

            VStack(spacing: 2) {
                MenuRow(symbol: "square.grid.2x2.fill", title: String(localized: "Recents"),
                        trailing: settings.shortcuts[.recents]?.displayString) {
                    run(actions.recents)
                }
                if cards > 0 {
                    MenuRow(symbol: "rectangle.on.rectangle", title: String(localized: "Close All Cards"),
                            trailing: "\(cards)") { run(actions.closeAllCards) }
                }
                MenuRow(symbol: "gearshape.fill", title: String(localized: "Settings…"), trailing: "⌘,") {
                    run(actions.settings)
                }
            }
            .padding(5)

            separator

            MenuRow(symbol: nil, title: String(localized: "Quit Hovr"), trailing: "⌘Q") { actions.quit() }
                .padding(5)
        }
        .frame(width: 244)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var separator: some View {
        Rectangle().fill(.primary.opacity(0.1)).frame(height: 1)
    }

    /// Closes first so a capture doesn't freeze the menu into the screenshot.
    private func run(_ action: @escaping () -> Void) {
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: action)
    }
}

private struct BigButton: View {
    let symbol: String
    let title: String
    let shortcut: String?
    let tint: NSColor
    let action: () -> Void
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(nsColor: tint))
                    Spacer()
                    if let shortcut {
                        Text(verbatim: shortcut)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(hovering ? 0.09 : 0))
            )
            .scaleEffect(pressed ? 0.97 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { pressed = true } }
            .onEnded { _ in withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { pressed = false } })
    }
}

private struct MenuToggleRow: View {
    let symbol: String
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title).font(.system(size: 13))
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() } }
    }
}

private struct MenuRow: View {
    let symbol: String?
    let title: String
    let trailing: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }
                Text(title).font(.system(size: 13))
                Spacer()
                if let trailing {
                    Text(verbatim: trailing)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.primary.opacity(hovering ? 0.09 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.1)) { hovering = h } }
    }
}
