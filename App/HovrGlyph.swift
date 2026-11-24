import AppKit

/// Hovr's mark: a rounded square whose top-right corner is peeled back in a soft, round fold,
/// like a card lifting off the screen. The same drawing is used for the menu bar icon (template) and,
/// copied, in tools/make_icons.swift for the app icon.
enum HovrGlyph {
    /// Draws into the current context, which must be transparent where the glyph goes (it erases the fold).
    static func draw(in r: NSRect, color: NSColor, flapAlpha: CGFloat = 0.6) {
        let u = r.width / 18
        let R = 7.2 * u                                            // size of the peeled corner
        let c = NSPoint(x: r.maxX - 1 * u, y: r.maxY - 1 * u)      // the corner being peeled
        let a = NSPoint(x: c.x, y: c.y - R), b = NSPoint(x: c.x - R, y: c.y)
        // The curl lies on the card, inside the round fold line: from the fold arc it bulges towards the centre.
        let p = NSPoint(x: c.x - R, y: c.y - R)
        let flap = NSBezierPath()
        flap.move(to: a)
        flap.appendArc(withCenter: c, radius: R, startAngle: 270, endAngle: 180, clockwise: true)
        flap.curve(to: a, controlPoint1: p, controlPoint2: p)
        flap.close()

        color.setFill()
        NSBezierPath(roundedRect: r.insetBy(dx: 1 * u, dy: 1 * u), xRadius: 3.6 * u, yRadius: 3.6 * u).fill()
        let ctx = NSGraphicsContext.current
        ctx?.saveGraphicsState()
        ctx?.compositingOperation = .clear
        // Corner removed along a round line, and a hairline gap around the fold.
        NSBezierPath(ovalIn: NSRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R)).fill()
        flap.lineWidth = 2.6 * u
        flap.lineJoinStyle = .round
        flap.stroke()
        ctx?.restoreGraphicsState()
        color.withAlphaComponent(flapAlpha).setFill()
        flap.fill()
    }

    static func image(size: CGFloat, color: NSColor, flapAlpha: CGFloat = 0.6) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            draw(in: r, color: color, flapAlpha: flapAlpha)
            return true
        }
    }

    /// The menu bar icon: 18 pt square, template (follows light and dark menu bars).
    static let menuBarImage: NSImage = {
        let img = image(size: 18, color: .black)
        img.isTemplate = true
        return img
    }()
}
