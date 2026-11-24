import AppKit
import QuartzCore
import UniformTypeIdentifiers

enum DockEdge: Int, Codable { case left, right }

/// Keeps track of the cards (pinned images and notes) floating above every window.
@MainActor
final class CardManager {
    static let shared = CardManager()
    private(set) var cards: [CardWindow] = []
    /// ⌃⌥V hides every card; pressing it again brings them back.
    private(set) var allHidden = false
    var onChange: (() -> Void)?

    func isOpen(_ id: UUID) -> Bool { cards.contains { $0.entryID == id } }
    func card(_ id: UUID) -> CardWindow? { cards.first { $0.entryID == id } }

    /// A just-captured card ends a little bigger than the selection (about 10%, at least 10 pt a side),
    /// so it stands out from the content it was copied from. Kept on screen.
    static func raised(_ r: NSRect) -> NSRect {
        let k = max(0.1, 20 / max(min(r.width, r.height), 1))
        let grow = min(k, 0.18)
        var f = r.insetBy(dx: -r.width * grow / 2, dy: -r.height * grow / 2)
        if let vf = (NSScreen.screens.first { $0.frame.intersects(r) } ?? NSScreen.main)?.visibleFrame, f.width < vf.width, f.height < vf.height {
            f.origin.x = min(max(f.minX, vf.minX + 4), vf.maxX - f.width - 4)
            f.origin.y = min(max(f.minY, vf.minY + 4), vf.maxY - f.height - 4)
        }
        return f.integral
    }

    /// A card's natural size: the capture at its size on screen, made smaller if it wouldn't fit comfortably.
    static func naturalSize(of image: CGImage, scale: CGFloat, near point: NSPoint? = nil) -> NSSize {
        var s = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let p = point ?? NSEvent.mouseLocation
        let vf = (NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let k = min(1, vf.width * 0.6 / s.width, vf.height * 0.6 / s.height)
        s = NSSize(width: (s.width * k).rounded(), height: (s.height * k).rounded())
        return s
    }

    /// A frame of `size` centred on `point` (or the screen with the pointer), kept inside the visible screen.
    static func frame(size: NSSize, centredOn point: NSPoint?) -> NSRect {
        let p = point ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let c = point ?? NSPoint(x: vf.midX, y: vf.midY)
        var r = NSRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
        r.origin.x = min(max(r.minX, vf.minX + 8), vf.maxX - r.width - 8)
        r.origin.y = min(max(r.minY, vf.minY + 8), vf.maxY - r.height - 8)
        return r.integral
    }

    // MARK: Opening

    /// Pins an image. With `from`, the card flies out of that rectangle (the selection).
    func pin(entry: HistoryEntry, image: CGImage, from source: NSRect? = nil, frame: NSRect? = nil, opacity: CGFloat = 1,
             animated: Bool = true) {
        if let open = card(entry.id) { open.bringBack(); return }
        showAll()
        // Right where it was selected, with the selection's shape and size; otherwise centred at its natural size.
        let target = frame ?? source.map(Self.raised) ?? Self.frame(size: Self.naturalSize(of: image, scale: entry.scale), centredOn: nil)
        let card = CardWindow(entry: entry, kind: .image(image, scale: entry.scale), frame: target)
        card.alphaValue = opacity
        cards.append(card)
        if animated { card.present(source.map { .lift(from: $0) } ?? .plain) } else { card.orderFrontRegardless() }
        saveOpenCards()
        onChange?()
    }

    func pin(_ id: UUID) {
        guard let entry = History.shared.entry(id) else { return }
        if entry.note { openNote(entry); return }
        guard let image = History.shared.image(for: id) else { return }
        pin(entry: entry, image: image)
    }

    /// Opens a saved note (or brings it back if it's open).
    func openNote(_ entry: HistoryEntry, frame: NSRect? = nil, opacity: CGFloat = 1, focus: Bool = false, animated: Bool = true,
                  popFrom: NSPoint? = nil) {
        if let open = card(entry.id) { open.bringBack(); return }
        showAll()
        let target = frame ?? Self.frame(size: NoteCardView.defaultSize, centredOn: nil)
        let card = CardWindow(entry: entry, kind: .note, frame: target)
        card.alphaValue = opacity
        cards.append(card)
        if animated { card.present(popFrom.map { .pop($0) } ?? .plain) } else { card.orderFrontRegardless() }
        if focus { card.beginEditing() }
        saveOpenCards()
        onChange?()
    }

    /// A new empty note where the user clicked (Text mode, no area selected).
    func newNote(at point: NSPoint) {
        let entry = History.shared.addNote(color: AppSettings.shared.newNoteColor())
        let size = NoteCardView.defaultSize
        let frame = Self.frame(size: size, centredOn: NSPoint(x: point.x + size.width / 2 - 20, y: point.y - size.height / 2 + 20))
        openNote(entry, frame: frame, focus: true, popFrom: point)
    }

    func closed(_ card: CardWindow) {
        cards.removeAll { $0 === card }
        saveOpenCards()
        onChange?()
    }

    func closeAll() { cards.forEach { $0.closeCard() } }

    /// Hides every card, or shows them again.
    func toggleVisibility() {
        guard !cards.isEmpty else { return }
        allHidden.toggle()
        for c in cards { allHidden ? c.orderOut(nil) : c.orderFrontRegardless() }
    }

    private func showAll() {
        guard allHidden else { return }
        allHidden = false
        cards.forEach { $0.orderFrontRegardless() }
    }

    // MARK: Pinch

    private var gestureMonitors: [Any] = []

    /// macOS sends pinch gestures to the active app, and cards belong to an app in the background.
    /// So pinches are also picked up with event monitors and applied to the card under the pointer.
    func installGestureMonitors() {
        guard gestureMonitors.isEmpty else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .magnify, handler: { [weak self] e in
            let mag = e.magnification, phase = e.phase
            MainActor.assumeIsolated {
                guard let self, self.tap == nil else { return }
                _ = self.pinch(mag, phase: phase, source: "global")
            }
        }) { gestureMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .magnify, handler: { [weak self] e in
            let mag = e.magnification, phase = e.phase
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                // With the gesture tap running it already resized the card; just swallow the event.
                if self.tap != nil { return self.cardUnderPointer() != nil }
                return self.pinch(mag, phase: phase, source: "local")
            }
            return handled ? nil : e
        }) { gestureMonitors.append(m) }
        startGestureTap()
    }

    // The reliable way: a listen-only event tap sees every pinch, whichever app is in front.
    // It needs Input Monitoring (asked from Settings → Advanced).
    private var tap: CFMachPort?
    var gestureTapRunning: Bool { tap != nil }

    func startGestureTap() {
        guard tap == nil else { return }
        guard CGPreflightListenEventAccess() else {
            Diag.log("gesture tap off: no Input Monitoring permission")
            return
        }
        let mask: CGEventMask = (1 << 29) | (1 << 30)   // gesture, magnify
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                        eventsOfInterest: mask, callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { CardManager.shared.reenableTap() }
            } else if let ns = NSEvent(cgEvent: event), ns.type == .magnify {
                // Taps get gestures as generic gesture events; NSEvent tells which one it is.
                let mag = ns.magnification, phase = ns.phase
                MainActor.assumeIsolated { _ = CardManager.shared.pinch(mag, phase: phase, source: "tap") }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil) else {
            Diag.log("gesture tap could not start")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        Diag.log("gesture tap running")
    }

    func reenableTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private var pinchCard: CardWindow?

    private func cardUnderPointer() -> CardWindow? {
        let p = NSEvent.mouseLocation
        let number = NSWindow.windowNumber(at: p, belowWindowWithWindowNumber: 0)
        return cards.first { $0.windowNumber == number } ?? cards.last { $0.isVisible && $0.frame.contains(p) }
    }

    @discardableResult
    func pinch(_ magnification: CGFloat, phase: NSEvent.Phase, source: String) -> Bool {
        if phase.contains(.began) || pinchCard == nil {
            pinchCard = cardUnderPointer()
            if phase.contains(.began) { Diag.log("pinch began (\(source)), on a card: \(pinchCard != nil)") }
        }
        guard let card = pinchCard else { return false }
        card.host.handleMagnify(magnification, phase: phase)
        if phase.contains(.ended) || phase.contains(.cancelled) { pinchCard = nil }
        return true
    }

    /// A display went away: cards left without a screen move to the main one.
    func screensChanged() {
        guard let main = NSScreen.screens.first else { return }
        for c in cards where !NSScreen.screens.contains(where: { $0.frame.intersects(c.frame) }) {
            let size = c.frame.size
            let vf = main.visibleFrame
            if let edge = c.dockEdge, AppSettings.shared.displayDisconnect == 0 {
                c.setFrame(NSRect(x: edge == .left ? main.frame.minX - size.width + CardWindow.tabWidth : main.frame.maxX - CardWindow.tabWidth,
                                  y: min(max(c.frame.minY, vf.minY), vf.maxY - size.height), width: size.width, height: size.height),
                           display: true)
            } else {
                if c.dockEdge != nil { c.releaseDockSilently() }
                c.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2, width: size.width, height: size.height),
                           display: true)
            }
        }
        saveOpenCards()
    }

    /// Docked cards on one edge of a screen (to stack new ones without overlap).
    func dockedFrames(edge: DockEdge, excluding: CardWindow) -> [NSRect] {
        cards.filter { $0 !== excluding && $0.dockEdge == edge }.map(\.frame)
    }

    // MARK: Restoring after relaunch

    private struct Saved: Codable {
        let id: UUID
        let frame: CGRect
        let opacity: CGFloat
        var locked: Bool?
        var dock: DockEdge?
        var undocked: CGRect?
    }
    private let savedKey = "openCards"

    private var restoring = false

    func saveOpenCards() {
        guard !restoring else { return }
        let saved = cards.map {
            Saved(id: $0.entryID, frame: $0.frame, opacity: $0.alphaValue, locked: $0.locked, dock: $0.dockEdge, undocked: $0.undockedFrame)
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: savedKey)
    }

    func restoreOpenCards() {
        guard AppSettings.shared.restoreCards,
              let data = UserDefaults.standard.data(forKey: savedKey),
              let saved = try? JSONDecoder().decode([Saved].self, from: data) else { return }
        restoring = true
        defer { restoring = false; saveOpenCards() }
        for s in saved {
            guard let entry = History.shared.entry(s.id) else { continue }
            let onScreen = NSScreen.screens.contains { $0.frame.intersects(s.frame) }
            // A docked card reopens at its full size first, then docks.
            let frame = onScreen ? (s.dock != nil ? (s.undocked ?? s.frame) : s.frame) : nil
            if entry.note {
                openNote(entry, frame: frame, opacity: s.opacity, animated: false)
            } else if let image = History.shared.image(for: s.id) {
                pin(entry: entry, image: image, frame: frame, opacity: s.opacity, animated: false)
            }
            guard let c = card(s.id) else { continue }
            c.locked = s.locked ?? false
            if let edge = s.dock, onScreen { c.restoreDocked(edge, undocked: s.undocked) }
        }
    }
}

// MARK: - Card window

/// One card: borderless, above normal windows, on every Space, over full-screen apps.
final class CardWindow: NSPanel {
    enum Kind {
        case image(CGImage, scale: CGFloat)
        case note
    }

    let entryID: UUID
    let kind: Kind
    let sourceApp: String?
    let host: CardHostView

    var isNote: Bool { if case .note = kind { return true } else { return false } }
    var image: CGImage? { if case let .image(img, _) = kind { return img } else { return nil } }
    var imageScale: CGFloat { if case let .image(_, s) = kind { return s } else { return 2 } }

    /// Locked cards can't be moved, resized or docked (⌘L).
    var locked = false { didSet { host.updateChrome() } }
    private(set) var dockEdge: DockEdge?
    private(set) var undockedFrame: NSRect?

    /// Image cards keep their shape when resized; notes resize freely.
    /// The image's own shape. Taken from the image, never from the window: window sizes get rounded to pixels,
    /// and reading the shape back from them made it drift during a pinch (the image seemed to zoom and slip away).
    var fixedAspect: CGFloat? {
        guard let image else { return nil }
        return CGFloat(image.width) / CGFloat(max(image.height, 1))
    }
    var cardMinSize: NSSize { isNote ? NSSize(width: 170, height: 120) : NSSize(width: 120, height: 80) }

    init(entry: HistoryEntry, kind: Kind, frame: NSRect) {
        entryID = entry.id
        self.kind = kind
        sourceApp = entry.sourceApp
        host = CardHostView(kind: kind, entry: entry)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false // moved by the host view so edges can resize
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
        // The host sits in a plain container, so its layer can be animated (scale, fade) by Core Animation;
        // AppKit manages the window content view's own layer.
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.autoresizingMask = [.width, .height]
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        contentView = container
        host.card = self
    }

    override var canBecomeKey: Bool { true }

    // MARK: Appearing and closing

    enum Entrance {
        /// Just captured: a flash on the selection, then the card jumps out of it and settles a little bigger.
        case lift(from: NSRect)
        /// A new note: fades in where it was clicked, growing a touch.
        case pop(NSPoint)
        /// Reopened: a quick fade and grow.
        case plain
    }

    /// Entrances run on Core Animation (in the window server, no work in the app per frame): the window is
    /// placed at its final frame at once and only the card's layer is scaled and faded in.
    func present(_ entrance: Entrance) {
        let final = frame
        let target = alphaValue
        alphaValue = target
        hasShadow = false          // the shadow comes back, matching the card, when the entrance ends
        orderFrontRegardless()
        makeKey()
        switch entrance {
        case let .lift(source):
            // Jumps out of the selection and settles a bit bigger, with a light spring.
            SelectionFlash.show(source)
            let sx = source.width / max(final.width, 1), sy = source.height / max(final.height, 1)
            let dx = source.midX - final.midX, dy = source.midY - final.midY
            host.animateEntrance(from: (sx, sy, dx, dy), fade: false, spring: true) { [weak self] in self?.entranceDone() }
        case .pop:
            // A soft fade in place, growing just a little.
            host.animateEntrance(from: (0.94, 0.94, 0, 0), fade: true, spring: false) { [weak self] in self?.entranceDone() }
        case .plain:
            host.animateEntrance(from: (0.95, 0.95, 0, 0), fade: true, spring: false) { [weak self] in self?.entranceDone() }
        }
    }

    private func entranceDone() {
        hasShadow = true
        invalidateShadow()
    }

    // MARK: Frame animation
    //
    // Window frames are animated here, frame by frame on the display link, with a spring. The system's
    // window animator could be cut short (a new note jumped to full size when its text view took focus).

    enum Motion {
        case bouncy, gentle, smooth, soft
        /// Angular frequency and damping ratio of the spring.
        var spring: (omega: Double, zeta: Double) {
            switch self {
            case .bouncy: (17, 0.55)
            case .gentle: (18, 0.8)
            case .smooth: (16, 1)
            case .soft: (11, 1)
            }
        }
    }

    private struct Glide {
        var from: NSRect, to: NSRect
        var alphaFrom: CGFloat, alphaTo: CGFloat
        var start: CFTimeInterval
        var motion: Motion
        var completion: (() -> Void)?
    }
    private static var glides: [ObjectIdentifier: Glide] = [:]
    private static var links: [ObjectIdentifier: CADisplayLink] = [:]

    func glide(to target: NSRect, alpha: CGFloat? = nil, motion: Motion = .smooth, completion: (() -> Void)? = nil) {
        let id = ObjectIdentifier(self)
        Self.glides[id] = Glide(from: frame, to: target, alphaFrom: alphaValue, alphaTo: alpha ?? alphaValue,
                                start: CACurrentMediaTime(), motion: motion, completion: completion)
        if Self.links[id] == nil {
            let l = displayLink(target: self, selector: #selector(glideTick(_:)))
            l.add(to: .main, forMode: .common)
            Self.links[id] = l
        }
    }

    func stopGlide() {
        let id = ObjectIdentifier(self)
        Self.links[id]?.invalidate()
        Self.links[id] = nil
        Self.glides[id] = nil
    }

    /// Spring position from 0 to 1 (overshoots when the damping is under 1).
    private static func spring(_ t: Double, _ motion: Motion) -> Double {
        let (w, z) = motion.spring
        if z >= 1 { return 1 - exp(-w * t) * (1 + w * t) }
        let wd = w * sqrt(1 - z * z)
        return 1 - exp(-z * w * t) * (cos(wd * t) + z * w / wd * sin(wd * t))
    }

    @objc private func glideTick(_ link: CADisplayLink) {
        let id = ObjectIdentifier(self)
        guard let g = Self.glides[id] else { stopGlide(); return }
        let t = CACurrentMediaTime() - g.start
        let p = CGFloat(Self.spring(t, g.motion))
        let f = NSRect(x: g.from.minX + (g.to.minX - g.from.minX) * p, y: g.from.minY + (g.to.minY - g.from.minY) * p,
                       width: max(1, g.from.width + (g.to.width - g.from.width) * p),
                       height: max(1, g.from.height + (g.to.height - g.from.height) * p))
        setFrame(f, display: true)
        let fade = g.motion == .soft ? 0.3 : 0.16
        let a = min(1, t / fade)
        alphaValue = g.alphaFrom + (g.alphaTo - g.alphaFrom) * CGFloat(a * a * (3 - 2 * a))
        if t > 0.25 && abs(1 - p) < 0.002 || t > 1.2 {
            setFrame(g.to, display: true)
            alphaValue = g.alphaTo
            stopGlide()
            invalidateShadow()
            g.completion?()
        }
    }

    /// Already open: undock it, bring it forward and blink once.
    func bringBack() {
        if dockEdge != nil { undock() }
        orderFrontRegardless()
        makeKey()
        let a = alphaValue
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; animator().alphaValue = 0.4 }) {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; self.animator().alphaValue = a }
        }
    }

    func closeCard() {
        stopGlide()
        host.stopInertia()
        host.commitNote()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.14; animator().alphaValue = 0 }) {
            MainActor.assumeIsolated {
                self.orderOut(nil)
                CardManager.shared.closed(self)
            }
        }
    }

    /// Notes: remove it for good. Images stay in Recents.
    func deleteCard() {
        if isNote { History.shared.delete(entryID) }
        closeCard()
    }

    func beginEditing() { host.beginEditing() }

    // MARK: Size, opacity, lock

    /// Sets the size (keeping image cards' shape) with `anchor` staying put relative to the card.
    func resize(to size: NSSize, around anchor: NSPoint) {
        var w = size.width, h = size.height
        if let a = fixedAspect { h = w / a }
        let minS = cardMinSize
        if w < minS.width { w = minS.width; if let a = fixedAspect { h = w / a } }
        if h < minS.height { h = minS.height; if let a = fixedAspect { w = h * a } }
        let maxSide: CGFloat = 5000
        if max(w, h) > maxSide { let k = maxSide / max(w, h); w *= k; h *= k }
        let f = frame
        let fx = (anchor.x - f.minX) / f.width, fy = (anchor.y - f.minY) / f.height
        setFrame(NSRect(x: anchor.x - fx * w, y: anchor.y - fy * h, width: w, height: h), display: true)
    }

    func zoom(by factor: CGFloat, around anchor: NSPoint? = nil) {
        let f = frame
        resize(to: NSSize(width: f.width * factor, height: f.height * factor), around: anchor ?? NSPoint(x: f.midX, y: f.midY))
    }

    /// Back to the capture's own size.
    func resetSize() {
        let f = frame
        let size: NSSize
        if let image { size = CardManager.naturalSize(of: image, scale: imageScale, near: NSPoint(x: f.midX, y: f.midY)) }
        else { size = NoteCardView.defaultSize }
        glide(to: NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2,
                         width: size.width, height: size.height).integral, motion: .gentle)
    }

    func setOpacity(_ value: CGFloat, showValue: Bool = true) {
        alphaValue = min(max(value, 0.1), 1)
        if showValue { host.showBadge("\(Int((alphaValue * 100).rounded()))%") }
    }

    func toggleLock() {
        locked.toggle()
        host.showBadge(locked ? String(localized: "Locked") : String(localized: "Unlocked"),
                       symbol: locked ? "lock.fill" : "lock.open.fill")
        CardManager.shared.saveOpenCards()
    }

    // MARK: Docking at a screen edge

    private var screenForCard: NSScreen? {
        let c = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(c) }
            ?? NSScreen.screens.min { $0.frame.distance(to: c) < $1.frame.distance(to: c) }
    }

    /// The edge the card has been pushed past, unless another screen continues there.
    func edgePushed(pointer: NSPoint? = nil) -> DockEdge? {
        guard !locked, dockEdge == nil, let screen = screenForCard else { return nil }
        let sf = screen.frame
        func freeBeyond(_ x: CGFloat) -> Bool {
            !NSScreen.screens.contains { $0 != screen && $0.frame.contains(NSPoint(x: x, y: frame.midY)) }
        }
        let margin: CGFloat = 28
        if (frame.minX < sf.minX - margin || (pointer?.x ?? .infinity) <= sf.minX + 1), freeBeyond(sf.minX - 4) { return .left }
        if (frame.maxX > sf.maxX + margin || (pointer?.x ?? -.infinity) >= sf.maxX - 1), freeBeyond(sf.maxX + 4) { return .right }
        return nil
    }

    /// Width of the card left on screen when it's docked.
    static let tabWidth: CGFloat = 12

    /// Slides the card off the screen edge until only a thin tab of it shows.
    func dock(_ edge: DockEdge, restoreTo restore: NSRect) {
        guard dockEdge == nil else { return }
        undockedFrame = restore
        EdgeGlow.shared.color = (isNote ? CaptureMode.text : CaptureMode.image).color
        EdgeGlow.shared.pulse(for: frame, edge: edge)
        dockEdge = edge
        host.setDocked(true)
        let target = dockedFrame(edge)
        glide(to: target, motion: .smooth)
        Feedback.whoosh()
        Feedback.tap()
        CardManager.shared.saveOpenCards()
    }

    /// Used when reopening after a relaunch: docked right away, without animation.
    func restoreDocked(_ edge: DockEdge, undocked: NSRect?) {
        undockedFrame = undocked ?? frame
        dockEdge = edge
        host.setDocked(true)
        setFrame(dockedFrame(edge), display: true)
    }

    /// Same size, pushed past the edge with only `tabWidth` showing, at the height it hit the edge.
    private func dockedFrame(_ edge: DockEdge) -> NSRect {
        let screen = screenForCard ?? NSScreen.main
        let sf = screen?.frame ?? .zero, vf = screen?.visibleFrame ?? .zero
        let size = (undockedFrame ?? frame).size
        let x = edge == .left ? sf.minX - size.width + Self.tabWidth : sf.maxX - Self.tabWidth
        var y = min(max(frame.minY, vf.minY + 8), vf.maxY - size.height - 8)
        // Tabs on the same edge don't cover each other.
        let others = CardManager.shared.dockedFrames(edge: edge, excluding: self)
        for _ in 0..<30 {
            let r = NSRect(x: x, y: y, width: size.width, height: size.height)
            guard let hit = others.first(where: { $0.insetBy(dx: 0, dy: -6).intersects(r) }) else { break }
            y = hit.minY - size.height - 8
            if y < vf.minY + 8 { y = vf.maxY - size.height - 8 }
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height).integral
    }

    /// Hovering the tab pulls the card out a little.
    func peek(_ on: Bool) {
        guard let edge = dockEdge else { return }
        var f = dockedFrame(edge)
        if on { f.origin.x += edge == .left ? 10 : -10 }
        glide(to: f, motion: .smooth)
    }

    /// Slides back onto the screen, where it was before docking.
    func undock() {
        guard dockEdge != nil else { return }
        dockEdge = nil
        var target = undockedFrame ?? frame
        if let vf = screenForCard?.visibleFrame {
            target.origin.x = min(max(target.minX, vf.minX + 8), vf.maxX - target.width - 8)
            target.origin.y = min(max(target.minY, vf.minY + 8), vf.maxY - target.height - 8)
        }
        host.setDocked(false)
        glide(to: target, motion: .gentle)
        makeKey()
        CardManager.shared.saveOpenCards()
    }

    /// Slides a card that ended partly off screen back on, unless cards may hang past the edge.
    func keepOnScreenIfNeeded() {
        guard !AppSettings.shared.hangPastEdge, dockEdge == nil,
              let vf = (NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main)?.visibleFrame,
              !vf.contains(frame) else { return }
        var f = frame
        f.origin.x = min(max(f.minX, vf.minX + 8), vf.maxX - f.width - 8)
        f.origin.y = min(max(f.minY, vf.minY + 8), vf.maxY - f.height - 8)
        glide(to: f, motion: .smooth)
    }

    func releaseDockSilently() {
        dockEdge = nil
        host.setDocked(false)
    }

    /// A docked card dragged away from the edge stays where it was dropped (kept on screen).
    func releaseDock() {
        guard dockEdge != nil else { return }
        dockEdge = nil
        host.setDocked(false)
        var f = frame
        if let vf = screenForCard?.visibleFrame {
            f.origin.x = min(max(f.minX, vf.minX + 8), vf.maxX - f.width - 8)
            f.origin.y = min(max(f.minY, vf.minY + 8), vf.maxY - f.height - 8)
        }
        glide(to: f, motion: .smooth)
        CardManager.shared.saveOpenCards()
    }

    // MARK: Actions

    func copyImage() {
        guard let image else { return }
        Pasteboard.copy(image: image, scale: imageScale)
        HUD.shared.show(String(localized: "Image copied"), symbol: "photo.on.rectangle")
    }

    /// Reads the text in the image (once) and copies it.
    func copyText() {
        if isNote {
            Pasteboard.copy(text: host.noteText)
            HUD.shared.show(String(localized: "Text copied"), symbol: "doc.on.clipboard")
            return
        }
        Task { @MainActor in
            let text = await History.shared.text(for: entryID) ?? ""
            if text.isEmpty {
                HUD.shared.show(String(localized: "No text found"), symbol: "text.magnifyingglass")
            } else {
                Pasteboard.copy(text: text)
                Feedback.shutter()
                HUD.shared.show(String(localized: "Text copied"), symbol: "doc.on.clipboard")
            }
        }
    }

    func saveImage() {
        guard let image else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let name = History.shared.entry(entryID)?.imageName ?? "Hovr.png"
        panel.nameFieldStringValue = name
        NSApp.activate(ignoringOtherApps: true)
        level = .normal
        let scale = imageScale
        panel.begin { [weak self] response in
            self?.level = .floating
            if response == .OK, let url = panel.url { History.writePNG(image, to: url, scale: scale) }
        }
    }

    // MARK: Keys

    /// Card shortcuts: ⌘W close, ⌘L lock, ⌘0–9 opacity; image cards also ⌘C, ⇧⌘C, ⌘S.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if mods == .command {
            switch chars {
            case "w": closeCard(); return true
            case "l": toggleLock(); return true
            case "0": setOpacity(1); return true
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                setOpacity(CGFloat(Int(chars)!) / 10); return true
            default: break
            }
            if !isNote {
                switch chars {
                case "c": copyImage(); return true
                case "s": saveImage(); return true
                case "=", "+": zoom(by: 1.1); return true
                case "-": zoom(by: 1 / 1.1); return true
                default: break
                }
            }
        }
        if !isNote, mods == [.command, .shift], chars == "c" { copyText(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

private extension NSRect {
    func distance(to p: NSPoint) -> CGFloat {
        let dx = max(minX - p.x, 0, p.x - maxX), dy = max(minY - p.y, 0, p.y - maxY)
        return hypot(dx, dy)
    }
}

// MARK: - Host view (shared by image and note cards)

/// Rounded card body: the content (image or note), the buttons, moving/resizing/zooming,
/// two-finger moves and throws, and the docked look.
final class CardHostView: NSView {
    weak var card: CardWindow?
    private let content: NSView
    private let note: NoteCardView?
    private let snapshotLayer = CALayer()
    private let closeButton: CardButton
    private let actionButton: CardButton   // image: extract text · note: checklist
    private let moreButton = CardButton(symbol: "ellipsis")
    private let badge = BadgeLabel()
    private let appIcon = NSImageView()
    private var hovering = false
    private(set) var docked = false

    private static let radius: CGFloat = 12
    private static let edge: CGFloat = 8
    /// Darkens the top of image cards so the buttons stay readable.
    private let topShade = TopShadeView()

    init(kind: CardWindow.Kind, entry: HistoryEntry) {
        switch kind {
        case let .image(img, _):
            content = ImageCardView(image: img)
            note = nil
            closeButton = CardButton(symbol: "xmark", style: .traffic)
            actionButton = CardButton(symbol: "text.viewfinder")
        case .note:
            let n = NoteCardView(entry: entry)
            content = n
            note = n
            closeButton = CardButton(symbol: "xmark", style: .traffic)
            actionButton = CardButton(symbol: "checklist", style: .plain)
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 0.5, alpha: 0.45).cgColor

        content.autoresizingMask = [.width, .height]
        addSubview(content)
        if note == nil { addSubview(topShade) }

        snapshotLayer.isHidden = true

        if note != nil { moreButton.style = .plain }
        for b in [closeButton, actionButton, moreButton] { addSubview(b) }
        closeButton.onClick = { [weak self] in self?.card?.closeCard() }
        moreButton.onClick = { [weak self] in self?.openMenu() }
        actionButton.onClick = { [weak self] in
            guard let self else { return }
            if let note = self.note { note.toggleChecklist() } else { self.card?.copyText() }
        }
        actionButton.toolTip = note == nil ? String(localized: "Extract Text") : String(localized: "Checklist")
        moreButton.toolTip = String(localized: "Options")

        badge.isHidden = true
        addSubview(badge)

        appIcon.isHidden = true
        appIcon.wantsLayer = true
        appIcon.layer?.zPosition = 20
        appIcon.shadow = { let s = NSShadow(); s.shadowBlurRadius = 3; s.shadowOffset = NSSize(width: 0, height: -1); s.shadowColor = NSColor.black.withAlphaComponent(0.4); return s }()
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        if let id = entry.sourceApp, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            appIcon.image = NSWorkspace.shared.icon(forFile: url.path)
        }
        addSubview(appIcon)
        if let note { note.onColorChange = { [weak self] in self?.updateChrome() } }
        updateChrome()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if snapshotLayer.superlayer == nil { layer?.addSublayer(snapshotLayer) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var noteText: String { note?.plainText ?? "" }
    func beginEditing() { note?.beginEditing() }
    func commitNote() { note?.saveNow() }

    override func layout() {
        super.layout()
        content.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        snapshotLayer.frame = bounds
        CATransaction.commit()
        topShade.frame = NSRect(x: 0, y: bounds.height - 48, width: bounds.width, height: 48)
        let s: CGFloat = 22, m: CGFloat = 6
        let top = bounds.height - s - m + (note != nil ? 2 : 0)
        closeButton.frame = NSRect(x: m, y: top, width: s, height: s)
        moreButton.frame = NSRect(x: bounds.width - s - m, y: top, width: s, height: s)
        actionButton.frame = NSRect(x: bounds.width - 2 * s - m - 4, y: top, width: s, height: s)
        let bw = badge.fittingSize.width
        badge.frame = NSRect(x: bounds.midX - bw / 2, y: bounds.midY - 12, width: bw, height: 24)
        updateChrome()
    }

    /// Buttons: on notes always there (faint until hover); on images only on hover. None when docked.
    func updateChrome() {
        let big = bounds.width >= 110 && bounds.height >= 60
        let show = !docked && big && (hovering || note != nil)
        for b in [closeButton, actionButton, moreButton] {
            b.isHidden = !show
            b.alphaValue = (note != nil && !hovering && b !== closeButton) ? 0.55 : 1
            if let note { b.tint = note.chromeColor }
        }
        closeButton.showsGlyph = hovering
        closeButton.isHidden = !show || card?.locked == true
        appIcon.isHidden = true
        // The shade at the top shows with the buttons (image cards only).
        let shade: Float = (note == nil && show) ? 1 : 0
        if topShade.layer?.opacity != shade {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.18)
            topShade.layer?.opacity = shade
            CATransaction.commit()
        }
    }

    func showBadge(_ text: String, symbol: String? = nil) { badge.show(text, symbol: symbol) ; needsLayout = true }

    // MARK: Entrance (Core Animation)

    /// Scales and fades the card in from `from` (x and y scale, offset of the centre) to its place.
    func animateEntrance(from: (CGFloat, CGFloat, CGFloat, CGFloat), fade: Bool, spring: Bool, completion: @escaping () -> Void) {
        guard let layer else { completion(); return }
        let b = bounds
        // View layers transform around their bottom-left corner: scale around the centre and add the offset.
        var t = CATransform3DMakeTranslation(b.midX + from.2, b.midY + from.3, 0)
        t = CATransform3DScale(t, from.0, from.1, 1)
        t = CATransform3DTranslate(t, -b.midX, -b.midY, 0)
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        if spring {
            let a = CASpringAnimation(keyPath: "transform")
            a.fromValue = NSValue(caTransform3D: t)
            a.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            a.mass = 1
            a.stiffness = 260
            a.damping = 19
            a.duration = a.settlingDuration
            layer.add(a, forKey: "entrance")
        } else {
            let a = CABasicAnimation(keyPath: "transform")
            a.fromValue = NSValue(caTransform3D: t)
            a.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            a.duration = 0.32
            a.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.3, 1)
            layer.add(a, forKey: "entrance")
        }
        if fade {
            let f = CABasicAnimation(keyPath: "opacity")
            f.fromValue = 0
            f.toValue = 1
            f.duration = 0.28
            f.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(f, forKey: "entranceFade")
        }
        CATransaction.commit()
    }

    // MARK: Docked look

    /// Docked: the card is off screen but for a thin tab; no buttons, a click brings it back.
    func setDocked(_ on: Bool) {
        docked = on
        if on { hovering = false }
        updateChrome()
    }

    // MARK: Hit testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        guard bounds.contains(p) else { return nil }
        if docked { return self }
        for b in [closeButton, actionButton, moreButton] where !b.isHidden && b.frame.contains(p) { return b }
        if edgeHit(p) != nil { return self }
        // Inside a note's writing area the text view gets the clicks while editing; otherwise the card does
        // (drag to move, double-click to edit).
        if let note, note.isTextArea(convert(p, to: note)), note.isEditing { return super.hitTest(point) }
        return self
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        if docked { if drag == nil { card?.peek(true) }; return }
        hovering = true
        updateChrome()
    }
    override func mouseExited(with event: NSEvent) {
        if docked { if drag == nil { card?.peek(false) }; return }
        hovering = false
        updateChrome()
        NSCursor.arrow.set()
    }
    override func mouseMoved(with event: NSEvent) {
        if !hovering { hovering = true; updateChrome() }
        updateCursor(convert(event.locationInWindow, from: nil))
    }
    override func cursorUpdate(with event: NSEvent) { updateCursor(convert(event.locationInWindow, from: nil)) }

    private func edgeHit(_ p: NSPoint) -> (left: Bool, right: Bool, bottom: Bool, top: Bool)? {
        guard !docked, card?.locked != true else { return nil }
        let e = min(Self.edge, bounds.width / 5, bounds.height / 5)
        let l = p.x < e, r = p.x > bounds.width - e, b = p.y < e, t = p.y > bounds.height - e
        return (l || r || b || t) ? (l, r, b, t) : nil
    }

    private func updateCursor(_ p: NSPoint) {
        if docked { NSCursor.pointingHand.set(); return }
        if let note, note.isTextArea(convert(p, to: note)), edgeHit(p) == nil { return } // text view sets its I-beam
        guard let hit = edgeHit(p) else { NSCursor.arrow.set(); return }
        if (hit.left || hit.right) && (hit.top || hit.bottom) { NSCursor.crosshair.set() }
        else if hit.left || hit.right { NSCursor.resizeLeftRight.set() }
        else { NSCursor.resizeUpDown.set() }
    }

    // MARK: Mouse: move, resize, dock, undock

    private enum Drag { case move(start: NSPoint, origin: NSPoint), resize(anchor: NSPoint, start: NSPoint, startSize: NSSize, h: Bool, v: Bool) }
    private var drag: Drag?
    private var dragStartFrame: NSRect = .zero
    private var dragMoved = false

    override func mouseDown(with event: NSEvent) {
        guard let card else { return }
        stopInertia()
        card.stopGlide()
        card.makeKey()
        if note != nil { window?.makeFirstResponder(self) }
        dragStartFrame = card.frame
        dragMoved = false
        let mouse = NSEvent.mouseLocation
        if event.clickCount == 2, !docked {
            if note != nil { note?.beginEditing() } else { card.resetSize() }
            drag = nil
            return
        }
        // Double-click to edit off: a click on a note that's already selected starts editing.
        if let note, !AppSettings.shared.doubleClickToEdit, event.clickCount == 1, card.isKeyWindow, !docked,
           note.isTextArea(convert(convert(event.locationInWindow, from: nil), to: note)) {
            note.beginEditing()
            drag = nil
            return
        }
        if card.locked && !docked { drag = nil; return }
        let p = convert(event.locationInWindow, from: nil)
        let f = card.frame
        if let hit = edgeHit(p) {
            // The anchor is the opposite corner/edge, which stays in place.
            let ax = hit.left ? f.maxX : (hit.right ? f.minX : f.midX)
            let ay = hit.bottom ? f.maxY : (hit.top ? f.minY : f.midY)
            drag = .resize(anchor: NSPoint(x: ax, y: ay), start: mouse, startSize: f.size,
                           h: hit.left || hit.right, v: hit.top || hit.bottom)
        } else {
            drag = .move(start: mouse, origin: f.origin)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let card, let drag else { return }
        let mouse = NSEvent.mouseLocation
        switch drag {
        case let .move(start, origin):
            if hypot(mouse.x - start.x, mouse.y - start.y) > 3 { dragMoved = true }
            guard dragMoved else { return }
            NSCursor.closedHand.set()
            card.setFrameOrigin(NSPoint(x: origin.x + mouse.x - start.x, y: origin.y + mouse.y - start.y))
            if !docked { card.updateEdgeGlow(pointer: mouse) }
        case let .resize(anchor, start, startSize, h, v):
            dragMoved = true
            let dx = (abs(mouse.x - anchor.x) - abs(start.x - anchor.x)) * (h ? 1 : 0)
            let dy = (abs(mouse.y - anchor.y) - abs(start.y - anchor.y)) * (v ? 1 : 0)
            var size = startSize
            if let a = card.fixedAspect {
                let grow = abs(dx) > abs(dy * a) ? dx : dy * a
                size = NSSize(width: startSize.width + grow, height: (startSize.width + grow) / a)
            } else {
                size = NSSize(width: startSize.width + dx, height: startSize.height + dy)
            }
            card.resize(to: size, around: anchor)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let card else { return }
        defer { drag = nil; CardManager.shared.saveOpenCards() }
        EdgeGlow.shared.hide()
        if docked {
            if !dragMoved { card.undock(); return }
            // Dragged away from the edge: it stays there; dropped at the edge: back into its tab.
            if card.edgePushedForDocked() == nil { card.releaseDock() } else { card.redock() }
            return
        }
        if case .move = drag, dragMoved, let edge = card.edgePushed(pointer: NSEvent.mouseLocation) {
            card.dock(edge, restoreTo: dragStartFrame)
        } else if dragMoved {
            card.keepOnScreenIfNeeded()
        }
    }

    override func rightMouseDown(with event: NSEvent) { if !docked { openMenu() } }

    // MARK: Two fingers: move (pointer follows), throw, pinch

    private var scrollCursor: NSPoint?
    private var scrollStartFrame: NSRect = .zero
    private var recent: [(t: TimeInterval, dx: CGFloat, dy: CGFloat)] = []
    private var velocity = CGVector.zero
    private var inertiaLink: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var pinchStart: NSRect?
    private var pinchTotal: CGFloat = 0
    private var pinchAnchor = NSPoint.zero

    override func scrollWheel(with event: NSEvent) {
        guard let card, !docked else { return }
        // Notes with more text than fits scroll their text instead.
        if let note, note.wantsScroll(event) { note.scrollText(event); return }
        if event.modifierFlags.contains(.option) {
            let d = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.scrollingDeltaY / 20
            card.setOpacity(card.alphaValue + d)
            return
        }
        guard !card.locked else { return }
        let trackpadMove = event.hasPreciseScrollingDeltas && AppSettings.shared.scrollMovesCard
            && !event.modifierFlags.contains(.command)
        guard trackpadMove else {
            // Mouse wheel (or ⌘ + scroll): zoom around the pointer.
            let d = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 300 : event.scrollingDeltaY / 15
            if d != 0 { card.zoom(by: 1 + max(min(d, 0.5), -0.5), around: NSEvent.mouseLocation) }
            return
        }
        // The system's own momentum is ignored: throws use our inertia below.
        if event.momentumPhase != [] { return }
        if event.phase.contains(.began) || scrollCursor == nil {
            stopInertia()
            card.stopGlide()
            scrollCursor = NSEvent.mouseLocation
            scrollStartFrame = card.frame
            recent.removeAll()
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            finishScrollMove()
            return
        }
        // The card follows the fingers, whatever the scroll direction setting.
        let inverted = event.isDirectionInvertedFromDevice
        let dx = inverted ? event.scrollingDeltaX : -event.scrollingDeltaX
        let dyDown = inverted ? event.scrollingDeltaY : -event.scrollingDeltaY
        guard dx != 0 || dyDown != 0 else { return }
        var o = card.frame.origin
        o.x += dx
        o.y -= dyDown
        card.setFrameOrigin(o)
        card.updateEdgeGlow()
        // Keep the pointer on the same spot of the card, so it never slides off it.
        if var c = scrollCursor {
            c.x += dx
            c.y -= dyDown
            scrollCursor = c
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            CGWarpMouseCursorPosition(CGPoint(x: c.x, y: primaryHeight - c.y))
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        let now = event.timestamp
        recent.append((now, dx, -dyDown))
        recent.removeAll { now - $0.t > 0.08 }
    }

    private func finishScrollMove() {
        guard let card else { return }
        scrollCursor = nil
        // Speed over the last moments decides whether it was a throw.
        if let first = recent.first, let last = recent.last, last.t > first.t {
            let dt = max(last.t - first.t, 0.016)
            let sx = recent.reduce(0) { $0 + $1.dx }, sy = recent.reduce(0) { $0 + $1.dy }
            velocity = CGVector(dx: sx / dt, dy: sy / dt)
        } else {
            velocity = .zero
        }
        recent.removeAll()
        if hypot(velocity.dx, velocity.dy) > AppSettings.shared.throwThreshold {
            Feedback.whoosh()
            startInertia()
        } else if let edge = card.edgePushed() {
            card.dock(edge, restoreTo: scrollStartFrame)
        } else {
            EdgeGlow.shared.hide()
            card.keepOnScreenIfNeeded()
            CardManager.shared.saveOpenCards()
        }
    }

    private func startInertia() {
        stopInertia()
        lastTick = CACurrentMediaTime()
        let l = displayLink(target: self, selector: #selector(inertiaTick(_:)))
        l.add(to: .main, forMode: .common)
        inertiaLink = l
    }

    func stopInertia() {
        inertiaLink?.invalidate()
        inertiaLink = nil
    }

    @objc private func inertiaTick(_ link: CADisplayLink) {
        guard let card else { stopInertia(); return }
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 1.0 / 30)
        lastTick = now
        var o = card.frame.origin
        o.x += velocity.dx * dt
        o.y += velocity.dy * dt
        card.setFrameOrigin(o)
        card.updateEdgeGlow()
        let friction = CGFloat(exp(-AppSettings.shared.throwFriction * dt))
        velocity.dx *= friction
        velocity.dy *= friction
        if let edge = card.edgePushed() {
            stopInertia()
            card.dock(edge, restoreTo: scrollStartFrame)
            return
        }
        if hypot(velocity.dx, velocity.dy) < 40 {
            stopInertia()
            EdgeGlow.shared.hide()
            // Landed partly off screen: slide back in (unless cards may hang past the edge).
            if !AppSettings.shared.hangPastEdge, let vf = (NSScreen.screens.first { $0.frame.intersects(card.frame) } ?? NSScreen.main)?.visibleFrame,
               !vf.contains(card.frame) {
                var f = card.frame
                f.origin.x = min(max(f.minX, vf.minX + 8), vf.maxX - f.width - 8)
                f.origin.y = min(max(f.minY, vf.minY + 8), vf.maxY - f.height - 8)
                card.glide(to: f, motion: .smooth)
            }
            CardManager.shared.saveOpenCards()
        }
    }

    override func magnify(with event: NSEvent) {
        if event.phase.contains(.began) { Diag.log("pinch began (view)") }
        handleMagnify(event.magnification, phase: event.phase)
    }

    /// Pinch to resize, accumulated from the start of the gesture so small steps never get rounded away.
    func handleMagnify(_ magnification: CGFloat, phase: NSEvent.Phase) {
        guard let card, !docked, !card.locked else { return }
        if phase.contains(.began) || pinchStart == nil {
            card.stopGlide()
            pinchStart = card.frame
            pinchTotal = 0
            pinchAnchor = NSEvent.mouseLocation
        }
        pinchTotal += magnification
        if let start = pinchStart {
            let k = max(0.2, 1 + pinchTotal)
            card.resize(to: NSSize(width: start.width * k, height: start.height * k), around: pinchAnchor)
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            pinchStart = nil
            CardManager.shared.saveOpenCards()
        }
    }

    // MARK: Keys and menu

    override func keyDown(with event: NSEvent) {
        guard let card else { return }
        switch Int(event.keyCode) {
        case 36, 76: if note != nil { note?.beginEditing() } else { super.keyDown(with: event) }   // ↩ edits a note
        case 123, 124, 125, 126:
            guard !card.locked, !docked else { return }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            var o = card.frame.origin
            switch event.keyCode {
            case 123: o.x -= step
            case 124: o.x += step
            case 125: o.y -= step
            default: o.y += step
            }
            card.setFrameOrigin(o)
        default: super.keyDown(with: event)
        }
    }

    private func openMenu() {
        guard let card else { return }
        let anchor = card.convertToScreen(moreButton.convert(moreButton.bounds, to: nil))
        CardMenuController.shared.show(for: card, below: anchor)
    }
}

extension CardWindow {
    /// For a docked card being dragged: is it still at an edge?
    func edgePushedForDocked() -> DockEdge? {
        guard let screen = (NSScreen.screens.first { $0.frame.intersects(frame) }) else { return dockEdge }
        let sf = screen.frame
        if frame.minX < sf.minX - frame.width / 2 { return .left }
        if frame.maxX > sf.maxX + frame.width / 2 { return .right }
        return nil
    }

    /// A docked card dropped near its edge snaps back into a slot there.
    func redock() {
        guard let edge = dockEdge else { return }
        let target = dockedFrame(edge)
        glide(to: target, motion: .smooth)
    }
}

// MARK: - Image content

/// The whole image, always. Cards keep the capture's shape, so it fills the card; any rounding leaves at most a
/// hairline of the backdrop colour instead of cutting the image.
final class ImageCardView: NSView {
    private let imageLayer = CALayer()

    init(image: CGImage) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Self.backdrop(for: image)
        imageLayer.contents = image
        imageLayer.contentsGravity = .resizeAspect   // the whole image, always
        imageLayer.masksToBounds = true
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    /// The image's average colour, darkened, for the bars around it.
    static func backdrop(for image: CGImage) -> CGColor {
        var px = [UInt8](repeating: 0, count: 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        if let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: cs,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let k: CGFloat = 0.55 / 255
        return CGColor(red: CGFloat(px[0]) * k, green: CGFloat(px[1]) * k, blue: CGFloat(px[2]) * k, alpha: 1)
    }
}

// MARK: - Small pieces

/// Round button on a card.
final class CardButton: NSView {
    enum Style { case circle, plain, dot, traffic }
    /// Traffic-light close button: the × shows while the card is hovered.
    var showsGlyph = false { didSet { if showsGlyph != oldValue { needsDisplay = true } } }
    var style: Style { didSet { needsDisplay = true } }
    var tint: NSColor = .white { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private let symbol: String
    private var hover = false
    private var pressed = false

    init(symbol: String, style: Style = .circle) {
        self.symbol = symbol
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { pressed = true; needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        switch style {
        case .circle:
            NSColor.black.withAlphaComponent(pressed ? 0.75 : 0.55).setFill()
            NSBezierPath(ovalIn: r).fill()
            NSColor.white.withAlphaComponent(0.25).setStroke()
            NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
            drawSymbol(color: .white, size: 9)
        case .plain:
            if hover || pressed {
                tint.withAlphaComponent(pressed ? 0.25 : 0.15).setFill()
                NSBezierPath(ovalIn: r).fill()
            }
            drawSymbol(color: tint, size: 11)
        case .traffic:
            // The red close button of a Mac window.
            let d: CGFloat = 13
            let c = NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
            NSColor(srgbRed: 1, green: 0.373, blue: 0.341, alpha: 1).setFill()          // #FF5F57
            NSBezierPath(ovalIn: c).fill()
            NSColor(srgbRed: 0.88, green: 0.267, blue: 0.243, alpha: 1).setStroke()      // #E0443E
            let ring = NSBezierPath(ovalIn: c.insetBy(dx: 0.25, dy: 0.25))
            ring.lineWidth = 0.5
            ring.stroke()
            if showsGlyph || hover {
                let x = NSBezierPath()
                let k: CGFloat = 3
                x.move(to: NSPoint(x: c.midX - k, y: c.midY - k)); x.line(to: NSPoint(x: c.midX + k, y: c.midY + k))
                x.move(to: NSPoint(x: c.midX - k, y: c.midY + k)); x.line(to: NSPoint(x: c.midX + k, y: c.midY - k))
                x.lineWidth = 1.4
                x.lineCapStyle = .round
                NSColor(srgbRed: 0.30, green: 0, blue: 0, alpha: pressed ? 0.9 : 0.7).setStroke()
                x.stroke()
            }
        case .dot:
            // A small dot that becomes a close button on hover.
            let d = r.insetBy(dx: 4, dy: 4)
            tint.withAlphaComponent(hover ? 0.6 : 0.35).setFill()
            NSBezierPath(ovalIn: d).fill()
            if hover { drawSymbol(color: tint.blended(withFraction: 0.5, of: .white) ?? .white, size: 7) }
        }
    }

    private func drawSymbol(color: NSColor, size: CGFloat) {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .bold).applying(.init(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        let s = img.size
        img.draw(in: NSRect(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2, width: s.width, height: s.height))
    }
}

/// "80%" or "Locked" in the middle of a card for a moment.
final class BadgeLabel: NSView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var hideWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        layer?.cornerRadius = 12
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        icon.contentTintColor = .white
        icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        addSubview(icon)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var fittingSize: NSSize {
        NSSize(width: label.fittingSize.width + (icon.image == nil ? 0 : 18) + 20, height: 24)
    }

    override func layout() {
        super.layout()
        let lw = label.fittingSize.width
        let iw: CGFloat = icon.image == nil ? 0 : 18
        let x = (bounds.width - lw - iw) / 2
        icon.frame = NSRect(x: x, y: 4, width: 14, height: 16)
        label.frame = NSRect(x: x + iw, y: (bounds.height - 16) / 2, width: lw, height: 16)
    }

    func show(_ text: String, symbol: String?) {
        label.stringValue = text
        icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        isHidden = false
        alphaValue = 1
        needsLayout = true
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; self?.animator().alphaValue = 0 }) {
                MainActor.assumeIsolated { self?.isHidden = true }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }
}

/// A soft dark gradient at the top of an image card, behind its buttons.
final class TopShadeView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        let g = CAGradientLayer()
        g.colors = [NSColor.black.withAlphaComponent(0.5).cgColor, NSColor.black.withAlphaComponent(0.18).cgColor,
                    NSColor.black.withAlphaComponent(0).cgColor]
        g.locations = [0, 0.45, 1]
        g.startPoint = CGPoint(x: 0.5, y: 1)   // top
        g.endPoint = CGPoint(x: 0.5, y: 0)
        g.opacity = 0
        layer = g
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Edge glow

/// A soft, thin light along the screen edge where a card is about to dock, in the card's colour.
/// It fades inwards and towards both ends, grows as the card gets closer, and pulses once when it docks.
@MainActor
final class EdgeGlow {
    static let shared = EdgeGlow()
    private var window: NSPanel?
    private let container = CALayer()
    private let glow = CAGradientLayer()      // across: colour on the edge → clear
    private let ends = CAGradientLayer()      // along: clear → opaque → clear (soft ends)
    private var edge: DockEdge = .left
    private static let width: CGFloat = 26
    private static let maxOpacity: Float = 0.55

    var color: NSColor = .systemBlue { didSet { applyColor() } }

    private func applyColor() {
        glow.colors = [color.withAlphaComponent(0.9).cgColor, color.withAlphaComponent(0.35).cgColor, color.withAlphaComponent(0).cgColor]
        glow.locations = [0, 0.3, 1]
    }

    private func makeWindow() -> NSPanel {
        let w = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let v = NSView()
        v.wantsLayer = true
        applyColor()
        ends.colors = [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.cgColor,
                       NSColor.black.cgColor, NSColor.black.withAlphaComponent(0).cgColor]
        ends.locations = [0, 0.3, 0.7, 1]
        ends.startPoint = CGPoint(x: 0.5, y: 0)
        ends.endPoint = CGPoint(x: 0.5, y: 1)
        glow.mask = ends
        container.opacity = 0
        container.addSublayer(glow)
        v.layer?.addSublayer(container)
        w.contentView = v
        return w
    }

    /// `strength` 0…1: how close the card is to docking on `edge`.
    func update(for card: NSRect, edge: DockEdge, strength: CGFloat) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(card) }) ?? NSScreen.main else { return }
        if window == nil { window = makeWindow() }
        guard let window else { return }
        self.edge = edge
        let sf = screen.frame
        let h = min(max(card.height * 1.4, 140), sf.height)
        let w = Self.width
        let y = min(max(card.midY - h / 2, sf.minY), sf.maxY - h)
        let x = edge == .left ? sf.minX : sf.maxX - w
        window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = CGRect(x: 0, y: 0, width: w, height: h)
        glow.frame = container.bounds
        ends.frame = glow.bounds
        glow.startPoint = CGPoint(x: edge == .left ? 0 : 1, y: 0.5)
        glow.endPoint = CGPoint(x: edge == .left ? 1 : 0, y: 0.5)
        CATransaction.commit()
        // Follows the card smoothly rather than jumping with every event.
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        container.opacity = Float(min(max(strength, 0), 1)) * Self.maxOpacity
        CATransaction.commit()
        if strength > 0 { window.orderFrontRegardless() }
    }

    func hide() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { if self.container.opacity == 0 { self.window?.orderOut(nil) } } }
        container.opacity = 0
        CATransaction.commit()
    }

    /// The card just docked: a gentle swell, then it fades away.
    func pulse(for card: NSRect, edge: DockEdge) {
        update(for: card, edge: edge, strength: 1)
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [Self.maxOpacity * 0.8, Self.maxOpacity, 0]
        a.keyTimes = [0, 0.3, 1]
        a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
        a.duration = 0.7
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { self.window?.orderOut(nil) } }
        container.add(a, forKey: "pulse")
        container.opacity = 0
        CATransaction.commit()
    }
}

extension CardWindow {
    /// While a card is moved: light the edge it's heading into (starts 90 pt before docking would happen).
    func updateEdgeGlow(pointer: NSPoint? = nil) {
        // Blue for image cards, red for text cards, like the capture modes.
        let c = (isNote ? CaptureMode.text : CaptureMode.image).color
        if EdgeGlow.shared.color != c { EdgeGlow.shared.color = c }
        guard !locked, dockEdge == nil,
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main else { return }
        let sf = screen.frame
        let leftGap = frame.minX - sf.minX, rightGap = sf.maxX - frame.maxX
        let reach: CGFloat = 90
        if let p = pointer, p.x <= sf.minX + 2 { EdgeGlow.shared.update(for: frame, edge: .left, strength: 1); return }
        if let p = pointer, p.x >= sf.maxX - 2 { EdgeGlow.shared.update(for: frame, edge: .right, strength: 1); return }
        if leftGap < reach, leftGap <= rightGap {
            EdgeGlow.shared.update(for: frame, edge: .left, strength: (reach - leftGap) / (reach + 28))
        } else if rightGap < reach {
            EdgeGlow.shared.update(for: frame, edge: .right, strength: (reach - rightGap) / (reach + 28))
        } else {
            EdgeGlow.shared.update(for: frame, edge: .left, strength: 0)
        }
    }
}
