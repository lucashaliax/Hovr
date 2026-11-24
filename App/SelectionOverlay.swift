import AppKit
import QuartzCore

/// A full-screen window showing the frozen screen, where the user drags an area or clicks a window.
final class SelectionOverlayWindow: NSWindow {
    let selectionView: SelectionView
    let image: CGImage

    init(screen: NSScreen, image: CGImage, windows: [NSRect], controller: CaptureController) {
        self.image = image
        selectionView = SelectionView(image: image, screenFrame: screen.frame, windows: windows, controller: controller)
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
        contentView = selectionView
        selectionView.overlay = self
        makeFirstResponder(selectionView)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func orderOut(_ sender: Any?) {
        selectionView.stopAnimating()
        super.orderOut(sender)
    }

    /// The frozen pixels under `rect`; with `polygon`, everything outside the shape is transparent.
    func crop(_ rect: NSRect, polygon: [NSPoint]?) -> CGImage? {
        guard let base = crop(rect) else { return nil }
        guard let polygon, polygon.count >= 3 else { return base }
        let w = base.width, h = base.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return base }
        let sx = CGFloat(w) / rect.width, sy = CGFloat(h) / rect.height
        let path = CGMutablePath()
        path.addLines(between: polygon.map { CGPoint(x: ($0.x - rect.minX) * sx, y: ($0.y - rect.minY) * sy) })
        path.closeSubpath()
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? base
    }

    /// The frozen pixels under `rect` (global screen points).
    func crop(_ rect: NSRect) -> CGImage? {
        let f = frame
        let sx = CGFloat(image.width) / f.width, sy = CGFloat(image.height) / f.height
        let local = rect.offsetBy(dx: -f.minX, dy: -f.minY)
        let px = CGRect(x: local.minX * sx, y: (f.height - local.maxY) * sy,
                        width: local.width * sx, height: local.height * sy).integral
        return image.cropping(to: px)
    }
}

/// Layer-based: the frozen screen is never redrawn. The highlighted rectangle (selection or hovered
/// window) glides to where it should be, one display frame at a time, and stops when it gets there.
final class SelectionView: NSView {
    weak var overlay: SelectionOverlayWindow?
    private let screenFrame: NSRect
    private let controller: CaptureController
    /// Window frames in this view's coordinates, front to back.
    private let windows: [NSRect]

    /// Selection / hovered window: clear inside, a soft glow outside the edge and a thin bright line.
    private let focusLayer = CALayer()
    private let fillLayer = CAShapeLayer()
    private let glowLayer = CALayer()          // holds both glows, masked to outside the edge
    private let glowWide = CAShapeLayer()
    private let glowMid = CAShapeLayer()
    private let glowTight = CAShapeLayer()
    private let glowMask = CAShapeLayer()
    private let lineLayer = CAShapeLayer()
    private let badge = CursorBadge()

    private var dragStart: NSPoint?
    private var selection: NSRect?
    private var hovered: NSRect?
    /// Clicking a window captures it (off by default; toggled in the menu bar popover).
    private var clickWindows = UserDefaults.standard.bool(forKey: "clickToCaptureWindow")
    /// Free-form selection: hold ⌥ and click the corners of what to keep.
    private var freeform: [NSPoint] = []
    private var freeformActive = false
    private var pointer = NSPoint.zero

    /// What is drawn now, and where it is heading.
    private var shown: CGRect?
    private var target: CGRect?
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0

    init(image: CGImage, screenFrame: NSRect, windows: [NSRect], controller: CaptureController) {
        self.screenFrame = screenFrame
        self.controller = controller
        let origin = screenFrame.origin
        self.windows = windows.compactMap { w in
            let local = w.offsetBy(dx: -origin.x, dy: -origin.y)
                .intersection(NSRect(origin: .zero, size: screenFrame.size))
            return local.isEmpty ? nil : local
        }
        super.init(frame: NSRect(origin: .zero, size: screenFrame.size))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        let root = layer!
        root.contents = image
        root.contentsGravity = .resize
        root.magnificationFilter = .nearest

        focusLayer.frame = bounds
        focusLayer.opacity = 0
        let still: [String: CAAction] = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(),
                                         "lineWidth": NSNull(), "shadowPath": NSNull()]
        for l in [fillLayer, glowLayer, glowWide, glowMid, glowTight, glowMask, lineLayer] {
            l.frame = bounds
            l.actions = still
        }
        lineLayer.fillColor = nil
        for (g, radius, opacity) in [(glowWide, CGFloat(12), Float(0.35)), (glowMid, CGFloat(6), Float(0.5)), (glowTight, CGFloat(2), Float(0.7))] {
            g.fillColor = nil
            g.strokeColor = nil
            g.shadowOffset = .zero
            g.shadowRadius = radius
            g.shadowOpacity = opacity
            glowLayer.addSublayer(g)
        }
        // The glow only shows outside the edge.
        glowMask.fillRule = .evenOdd
        glowMask.fillColor = NSColor.black.cgColor
        glowLayer.mask = glowMask
        focusLayer.addSublayer(fillLayer)
        focusLayer.addSublayer(glowLayer)
        focusLayer.addSublayer(lineLayer)
        root.addSublayer(focusLayer)
        // Slow breathing of the glow, run by Core Animation (no work on our side per frame).
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.65
        breathe.toValue = 1
        breathe.duration = 1.3
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowLayer.add(breathe, forKey: "breathe")
        applyColors(animated: false)

        badge.mode = controller.mode
        badge.clickWindows = clickWindows
        badge.showsHint = Self.shouldShowHint
        addSubview(badge)

        let mouse = NSEvent.mouseLocation
        if screenFrame.contains(mouse) {
            badge.appear()
            pointerMoved(to: NSPoint(x: mouse.x - origin.x, y: mouse.y - origin.y))
        } else {
            badge.isHidden = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    /// The hint next to the pointer shows for the first few captures only.
    private static let hintKey = "selectionHintCount"
    private static var shouldShowHint: Bool { UserDefaults.standard.integer(forKey: hintKey) < 5 }
    static func countHint() {
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: hintKey) + 1, forKey: hintKey)
    }

    func modeChanged() {
        badge.mode = controller.mode
        applyColors(animated: true)
    }

    /// Blue for Image, red for Text; a soft cross-fade when Tab switches.
    private func applyColors(animated: Bool) {
        let color = controller.mode.color
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.2)
        lineLayer.strokeColor = color.blended(withFraction: 0.45, of: .white)?.cgColor ?? color.cgColor
        for g in [glowWide, glowMid, glowTight] { g.shadowColor = color.cgColor }
        fillLayer.fillColor = nil // the area inside stays exactly as it is
        CATransaction.commit()
    }

    // MARK: Gliding rectangle

    private func setTarget(_ rect: CGRect?, from start: CGRect? = nil) {
        if let rect {
            if shown == nil || focusLayer.opacity == 0 { shown = start ?? rect.insetBy(dx: rect.width * 0.03, dy: rect.height * 0.03) }
            target = rect
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.12)
            focusLayer.opacity = 1
            CATransaction.commit()
        } else {
            target = nil
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            focusLayer.opacity = 0
            CATransaction.commit()
        }
        startAnimating()
    }

    private func startAnimating() {
        guard link == nil, target != nil else { return }
        lastTick = CACurrentMediaTime()
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stopAnimating() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ l: CADisplayLink) {
        guard let target, var cur = shown else { stopAnimating(); return }
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 1.0 / 30)
        lastTick = now
        // Exponential approach: fast, smooth, no overshoot. Dragging follows tighter than hovering.
        let rate: Double = selection != nil ? 38 : 22
        let k = CGFloat(1 - exp(-rate * dt))
        cur.origin.x += (target.minX - cur.minX) * k
        cur.origin.y += (target.minY - cur.minY) * k
        cur.size.width += (target.width - cur.width) * k
        cur.size.height += (target.height - cur.height) * k
        let done = abs(cur.minX - target.minX) < 0.3 && abs(cur.minY - target.minY) < 0.3
            && abs(cur.width - target.width) < 0.3 && abs(cur.height - target.height) < 0.3
        if done { cur = target }
        shown = cur
        drawFocus(cur)
        if done { stopAnimating() }
    }

    private func drawFocus(_ r: CGRect) {
        let path: CGPath
        if freeformActive {
            return
        } else if selection != nil {
            path = CGPath(rect: r, transform: nil)
        } else {
            let radius = min(10, r.width / 4, r.height / 4)
            path = CGPath(roundedRect: r.insetBy(dx: 1, dy: 1), cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.path = path
        lineLayer.path = path
        lineLayer.lineWidth = selection != nil ? 1 : 1.5
        glowWide.shadowPath = path.copy(strokingWithWidth: 8, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
        glowMid.shadowPath = path.copy(strokingWithWidth: 4, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
        glowTight.shadowPath = path.copy(strokingWithWidth: 2, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
        let mask = CGMutablePath()
        mask.addRect(bounds)
        mask.addPath(path)
        glowMask.path = mask
        CATransaction.commit()
    }

    /// The free-form outline so far, closed back to the first corner through the pointer.
    private func drawFreeform() {
        guard freeformActive else { return }
        let path = CGMutablePath()
        if let first = freeform.first {
            path.move(to: first)
            for q in freeform.dropFirst() { path.addLine(to: q) }
            path.addLine(to: pointer)
            if freeform.count >= 2 { path.closeSubpath() }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        focusLayer.opacity = freeform.isEmpty ? 0 : 1
        fillLayer.path = nil
        lineLayer.path = path
        lineLayer.lineWidth = 1.5
        let stroke = path.copy(strokingWithWidth: 4, lineCap: .round, lineJoin: .round, miterLimit: 10)
        glowWide.shadowPath = stroke
        glowMid.shadowPath = stroke
        glowTight.shadowPath = path.copy(strokingWithWidth: 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
        glowMask.path = CGPath(rect: bounds, transform: nil)
        CATransaction.commit()
    }

    private func pointerMoved(to p: NSPoint) {
        badge.isHidden = false
        badge.place(at: p, in: bounds)
        pointer = p
        if freeformActive { drawFreeform(); return }
        guard selection == nil, dragStart == nil else { return }
        let new = clickWindows ? windows.first { $0.contains(p) } : nil
        if new != hovered {
            hovered = new
            setTarget(new)
        }
    }

    // MARK: Mouse

    override func mouseEntered(with event: NSEvent) { badge.appear() }

    override func mouseExited(with event: NSEvent) {
        badge.isHidden = true
        if selection == nil { hovered = nil; setTarget(nil) }
    }

    override func mouseMoved(with event: NSEvent) {
        pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if freeformActive || event.modifierFlags.contains(.option) {
            if !freeformActive { startFreeform() }
            freeform.append(p)
            pointer = p
            drawFreeform()
            return
        }
        dragStart = p
        selection = nil
    }

    private func startFreeform() {
        freeformActive = true
        freeform = []
        stopAnimating()
        hovered = nil
        target = nil
        shown = nil
        focusLayer.opacity = 0
    }

    /// Releasing ⌥ captures the outlined shape (three corners or more).
    override func flagsChanged(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            if !freeformActive && dragStart == nil { startFreeform() }
        } else if freeformActive {
            let pts = freeform
            freeformActive = false
            freeform = []
            focusLayer.opacity = 0
            guard pts.count >= 3, let overlay else { return }
            let xs = pts.map(\.x), ys = pts.map(\.y)
            let box = NSRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).integral
            guard box.width >= 4, box.height >= 4 else { return }
            Self.countHint()
            let global = pts.map { NSPoint(x: $0.x + screenFrame.minX, y: $0.y + screenFrame.minY) }
            controller.finish(rect: box.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY), on: overlay, polygon: global)
        }
        super.flagsChanged(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        var p = convert(event.locationInWindow, from: nil)
        p.x = min(max(p.x, 0), bounds.width)
        p.y = min(max(p.y, 0), bounds.height)
        if event.modifierFlags.contains(.shift) {
            // ⇧: a square.
            let side = max(abs(p.x - start.x), abs(p.y - start.y))
            p.x = start.x + (p.x >= start.x ? side : -side)
            p.y = start.y + (p.y >= start.y ? side : -side)
        }
        let r = NSRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        let wasSelecting = selection != nil
        selection = r.width >= 3 || r.height >= 3 ? r : nil
        if let selection {
            // A new selection grows out of the point where the drag began.
            setTarget(selection, from: wasSelecting ? nil : CGRect(origin: start, size: .zero))
            if !wasSelecting { shown = CGRect(origin: start, size: .zero) }
        } else {
        }
        badge.place(at: p, in: bounds)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        let local: NSRect
        if let selection, selection.width >= 4, selection.height >= 4 {
            local = selection.integral
        } else if let hovered {
            local = hovered
        } else {
            selection = nil
            setTarget(nil)
            // In Text mode a plain click makes an empty note there; in Image mode it does nothing.
            if controller.mode == .text {
                let p = convert(event.locationInWindow, from: nil)
                controller.createNote(at: NSPoint(x: p.x + screenFrame.minX, y: p.y + screenFrame.minY))
            }
            return
        }
        selection = nil
        guard let overlay else { return }
        Self.countHint()
        controller.finish(rect: local.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY), on: overlay)
    }

    override func rightMouseDown(with event: NSEvent) { controller.cancel() }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: controller.cancel()                       // ⎋
        case 48: controller.toggleMode()                   // ⇥
        case 34: controller.setMode(.image)                // I
        case 17: controller.setMode(.text)                 // T
        case 49:                                           // Space: a whole window, on or off
            clickWindows.toggle()
            badge.clickWindows = clickWindows
            Feedback.tap()
            hovered = nil
            if clickWindows { pointerMoved(to: pointer) } else { setTarget(nil) }
        case 36, 76:                                       // ↩ captures the window under the pointer
            if let hovered, let overlay {
                Self.countHint()
                controller.finish(rect: hovered.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY), on: overlay)
            }
        default: super.keyDown(with: event)
        }
    }
}

// MARK: - Pointer badge

/// Small pill next to the crosshair showing Image / Text, the active one in its mode colour.
/// It is redrawn only when the mode changes; moving it just sets its frame.
final class CursorBadge: NSView {
    var mode: CaptureMode = .image { didSet { if mode != oldValue { needsDisplay = true } } }
    var clickWindows = false
    var showsHint = false {
        didSet { setFrameSize(intrinsicSize) }
    }

    private static let seg: CGFloat = 24
    private static let pad: CGFloat = 3
    private static let gap: CGFloat = 8
    private var pillSize: NSSize { NSSize(width: Self.seg + Self.pad * 2, height: Self.seg * 2 + Self.pad * 2) }

    private lazy var hint: NSAttributedString = {
        let title = NSMutableAttributedString(string: String(localized: "Tab: Image / Text · Space: window · ⌥: free-form") + "\n",
                                              attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                                                           .foregroundColor: NSColor.white])
        title.append(NSAttributedString(string: clickWindows ? String(localized: "Click a window or drag an area · Esc cancels")
                                                     : String(localized: "Drag an area · Esc cancels"),
                                        attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .regular),
                                                     .foregroundColor: NSColor(white: 1, alpha: 0.7)]))
        return title
    }()
    private var hintSize: NSSize {
        let s = hint.boundingRect(with: NSSize(width: 400, height: 100), options: [.usesLineFragmentOrigin]).size
        return NSSize(width: ceil(s.width) + 28, height: ceil(s.height) + 14)
    }

    private var intrinsicSize: NSSize {
        guard showsHint else { return pillSize }
        let h = hintSize
        return NSSize(width: pillSize.width + Self.gap + h.width, height: max(pillSize.height, h.height))
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        setFrameSize(pillSize)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        self.shadow = shadow
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil } // never blocks the selection

    /// Fades in when the selection opens.
    func appear() {
        guard isHidden || layer?.opacity == 0 || alphaValue < 1 else { return }
        isHidden = false
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            animator().alphaValue = 1
        }
    }

    /// Places the badge just right of the pointer, flipping sides near the screen edges.
    func place(at p: NSPoint, in bounds: NSRect) {
        let s = frame.size
        var x = p.x + 16
        if x + s.width > bounds.maxX - 4 { x = p.x - 16 - s.width }
        var y = p.y - s.height / 2
        y = min(max(y, bounds.minY + 4), bounds.maxY - s.height - 4)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSRect(x: 0, y: (bounds.height - pillSize.height) / 2, width: pillSize.width, height: pillSize.height)
        NSColor(white: 0.1, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.width / 2, yRadius: pill.width / 2).fill()
        NSColor(white: 1, alpha: 0.15).setStroke()
        let edge = NSBezierPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), xRadius: pill.width / 2 - 0.5, yRadius: pill.width / 2 - 0.5)
        edge.lineWidth = 1
        edge.stroke()

        // Image on top, Text below.
        for m in CaptureMode.allCases {
            let y = m == .image ? pill.maxY - Self.pad - Self.seg : pill.minY + Self.pad
            let r = NSRect(x: pill.minX + Self.pad, y: y, width: Self.seg, height: Self.seg)
            let active = m == mode
            if active {
                m.color.setFill()
                NSBezierPath(ovalIn: r).fill()
            }
            let color = active ? NSColor.white : NSColor(white: 1, alpha: 0.55)
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold).applying(.init(paletteColors: [color]))
            if let icon = NSImage(systemSymbolName: m == .image ? "photo" : "textformat", accessibilityDescription: m.title)?
                .withSymbolConfiguration(cfg) {
                let s = icon.size
                icon.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
            }
        }

        guard showsHint else { return }
        let hs = hintSize
        let box = NSRect(x: pill.maxX + Self.gap, y: (bounds.height - hs.height) / 2, width: hs.width, height: hs.height)
        NSColor(white: 0.1, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        hint.draw(with: box.insetBy(dx: 14, dy: 7), options: [.usesLineFragmentOrigin])
    }
}
