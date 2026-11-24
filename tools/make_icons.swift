// Draws the Hovr app icon. The mark comes from App/HovrGlyph.swift, so run it together with that file:
//   cat App/HovrGlyph.swift tools/make_icons.swift > /tmp/hovr_icons.swift && swift /tmp/hovr_icons.swift
import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let rgb = CGColorSpaceCreateDeviceRGB()

func drawAppIcon(size s: CGFloat, in ctx: CGContext) {
    let u = s / 1024
    let body = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186 * u, cornerHeight: 186 * u, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 28 * u, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.5, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Deep blue to violet, with a soft light from the top.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: rgb, colors: [
        CGColor(red: 0.36, green: 0.42, blue: 0.98, alpha: 1),
        CGColor(red: 0.42, green: 0.27, blue: 0.86, alpha: 1),
        CGColor(red: 0.22, green: 0.12, blue: 0.50, alpha: 1),
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    let hl = CGGradient(colorsSpace: rgb, colors: [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(hl, startCenter: CGPoint(x: body.midX, y: body.maxY), startRadius: 0,
                           endCenter: CGPoint(x: body.midX, y: body.maxY), endRadius: 600 * u, options: [])
    ctx.restoreGState()

    // The mark, white, with a soft shadow so it seems to hover.
    let side = 470 * u
    let markRect = NSRect(x: body.midX - side / 2, y: body.midY - side / 2 - 6 * u, width: side, height: side)
    let mark = HovrGlyph.image(size: side, color: .white, flapAlpha: 0.62)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * u), blur: 36 * u, color: CGColor(red: 0.08, green: 0.02, blue: 0.25, alpha: 0.55))
    if let cg = mark.cgImage(forProposedRect: nil, context: nil, hints: nil) { ctx.draw(cg, in: markRect) }
    ctx.restoreGState()
}

func png(size: Int, scale: Int, draw: (CGFloat, CGContext) -> Void) -> Data {
    let px = size * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    draw(CGFloat(px), ctx)
    return rep.representation(using: .png, properties: [:])!
}

let assets = root.appendingPathComponent("App/Resources/Assets.xcassets")
let iconSet = assets.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try png(size: size, scale: scale, draw: drawAppIcon).write(to: iconSet.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
    }
}
try JSONSerialization.data(withJSONObject: ["images": images, "info": ["version": 1, "author": "xcode"]], options: .prettyPrinted)
    .write(to: iconSet.appendingPathComponent("Contents.json"))
try #"{"info":{"version":1,"author":"xcode"}}"#.data(using: .utf8)!.write(to: assets.appendingPathComponent("Contents.json"))
try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
try png(size: 1024, scale: 1, draw: drawAppIcon).write(to: root.appendingPathComponent("docs/icon.png"))
print("icons written")
