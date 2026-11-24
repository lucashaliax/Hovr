// Generates Hovr's promotional images (2880×1800 PNG).
// Run from the repository root:
//   swiftc -O -swift-version 5 Promo/PromoRenderer.swift -o build/promo-render && build/promo-render
import AppKit
import SwiftUI

// MARK: - Palette (from the app icon: blue → violet; blue = Image, red = Text)

let canvas = CGSize(width: 1440, height: 900)
let ink = Color.white
let inkSecondary = Color(white: 0.68)
let blue = Color(red: 0.36, green: 0.42, blue: 0.98)
let violet = Color(red: 0.42, green: 0.27, blue: 0.86)
let deep = Color(red: 0.22, green: 0.12, blue: 0.50)
let imageBlue = Color(nsColor: .systemBlue)
let textRed = Color(nsColor: .systemRed)
let lemon = Color(red: 1.0, green: 0.914, blue: 0.478)

let appIcon = NSImage(contentsOfFile: "docs/icon.png") ?? NSImage()

struct Backdrop: View {
    var glows: [(Color, CGPoint, CGFloat)] = [
        (blue, CGPoint(x: 0.10, y: 0.08), 640),
        (violet, CGPoint(x: 0.92, y: 0.30), 560),
        (deep, CGPoint(x: 0.65, y: 1.05), 600),
    ]
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.06, blue: 0.14), Color(red: 0.02, green: 0.02, blue: 0.05)],
                           startPoint: .top, endPoint: .bottom)
            ForEach(Array(glows.enumerated()), id: \.offset) { _, g in
                Circle().fill(g.0)
                    .frame(width: g.2, height: g.2)
                    .position(x: g.1.x * canvas.width, y: g.1.y * canvas.height)
                    .blur(radius: 160)
                    .opacity(0.5)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
    }
}

// MARK: - Pieces

struct Keycap: View {
    var label: String
    var size: CGFloat = 64
    var accent = false
    var body: some View {
        Text(label)
            .font(.system(size: size * 0.40, weight: .medium, design: .rounded))
            .foregroundStyle(accent ? Color.white : ink)
            .frame(minWidth: size, minHeight: size)
            .padding(.horizontal, label.count > 2 ? size * 0.22 : 0)
            .background {
                let shape = RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                ZStack {
                    shape.fill(accent ? LinearGradient(colors: [blue, violet], startPoint: .top, endPoint: .bottom)
                                      : LinearGradient(colors: [Color(white: 0.30), Color(white: 0.17)], startPoint: .top, endPoint: .bottom))
                    shape.strokeBorder(.white.opacity(accent ? 0.45 : 0.22), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.5), radius: 0, y: size * 0.06)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
            }
    }
}

struct Keys: View {
    var keys: [String]
    var size: CGFloat = 64
    var body: some View {
        HStack(spacing: size * 0.16) {
            ForEach(Array(keys.enumerated()), id: \.offset) { i, k in
                Keycap(label: k, size: size, accent: i == keys.count - 1)
            }
        }
    }
}

/// A mountain landscape, the "reference" people capture in every mockup.
struct Scene: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                LinearGradient(colors: [Color(red: 0.98, green: 0.80, blue: 0.62), Color(red: 0.93, green: 0.55, blue: 0.47),
                                        Color(red: 0.45, green: 0.30, blue: 0.62)], startPoint: .top, endPoint: .bottom)
                Circle().fill(Color(red: 1, green: 0.95, blue: 0.85)).frame(width: h * 0.22, height: h * 0.22)
                    .position(x: w * 0.70, y: h * 0.36)
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * 0.78))
                    p.addLine(to: CGPoint(x: w * 0.22, y: h * 0.40)); p.addLine(to: CGPoint(x: w * 0.38, y: h * 0.62))
                    p.addLine(to: CGPoint(x: w * 0.58, y: h * 0.30)); p.addLine(to: CGPoint(x: w * 0.82, y: h * 0.68))
                    p.addLine(to: CGPoint(x: w, y: h * 0.52)); p.addLine(to: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: 0, y: h))
                    p.closeSubpath()
                }
                .fill(Color(red: 0.22, green: 0.16, blue: 0.36))
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * 0.90))
                    p.addCurve(to: CGPoint(x: w, y: h * 0.82), control1: CGPoint(x: w * 0.35, y: h * 0.74), control2: CGPoint(x: w * 0.7, y: h * 0.96))
                    p.addLine(to: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: 0, y: h)); p.closeSubpath()
                }
                .fill(Color(red: 0.12, green: 0.09, blue: 0.20))
            }
        }
    }
}

/// A plain Mac window with lines of text and a picture, standing in for any app.
struct AppWindow: View {
    var title = "Moodboard"
    var picture = true
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) {
                    Circle().fill($0).frame(width: 12, height: 12)
                }
                Spacer()
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(inkSecondary)
                Spacer()
                Color.clear.frame(width: 52)
            }
            .padding(.horizontal, 16).frame(height: 40)
            .background(Color(white: 0.16))
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(0..<9) { i in
                        RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.24)).frame(width: [180, 150, 170, 120, 160, 140, 175, 110, 150][i], height: 9)
                    }
                }
                .padding(.top, 8)
                if picture { Scene().clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)) }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(white: 0.11))
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.10)))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
    }
}

/// The selection while dragging: thin line, soft glow outside, clear inside.
struct SelectionGlow: View {
    var color: Color = imageBlue
    var body: some View {
        Rectangle()
            .strokeBorder(color.opacity(0.95), lineWidth: 1.5)
            .shadow(color: color.opacity(0.9), radius: 4)
            .shadow(color: color.opacity(0.6), radius: 14)
    }
}

/// The Image / Text pill next to the crosshair.
struct ModeBadge: View {
    var text = false
    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: "photo").font(.system(size: 12, weight: .bold))
                .frame(width: 26, height: 26).background(Circle().fill(text ? .clear : imageBlue))
                .foregroundStyle(.white.opacity(text ? 0.55 : 1))
            Image(systemName: "textformat").font(.system(size: 12, weight: .bold))
                .frame(width: 26, height: 26).background(Circle().fill(text ? textRed : .clear))
                .foregroundStyle(.white.opacity(text ? 1 : 0.55))
        }
        .padding(3)
        .background(Capsule().fill(Color(white: 0.1).opacity(0.92)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
    }
}

/// A floating image card with its buttons.
struct ImageCard: View {
    var width: CGFloat = 330
    var height: CGFloat = 220
    var buttons = true
    var body: some View {
        ZStack(alignment: .top) {
            Scene()
            if buttons {
                LinearGradient(colors: [.black.opacity(0.5), .black.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 46)
                HStack {
                    Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 13, height: 13)
                        .overlay(Image(systemName: "xmark").font(.system(size: 7, weight: .black)).foregroundStyle(Color(red: 0.3, green: 0, blue: 0).opacity(0.7)))
                    Spacer()
                    ForEach(["text.viewfinder", "ellipsis"], id: \.self) { s in
                        Image(systemName: s).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 22, height: 22).background(Circle().fill(.black.opacity(0.55)))
                    }
                }
                .padding(8)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.55), radius: 26, y: 14)
    }
}

/// A yellow text card with a checklist.
struct NoteCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                Spacer()
                Image(systemName: "checklist").font(.system(size: 11, weight: .semibold))
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.black.opacity(0.55))
            row("Palette: warm dusk", done: true)
            row("Crop the mountains", done: false)
            row("Send to the client", done: false)
            Text("• Ref: hero image\n• Font: SF Pro Rounded").font(.system(size: 14)).foregroundStyle(.black.opacity(0.8)).padding(.top, 2)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 250, height: 240)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(lemon))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
    }

    func row(_ t: String, done: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15)).foregroundStyle(done ? Color.green : .black.opacity(0.35))
            Text(t).font(.system(size: 14)).strikethrough(done).foregroundStyle(.black.opacity(done ? 0.4 : 0.85))
        }
    }
}

/// A soft desktop background, so mockups read as a screen.
struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.30, green: 0.27, blue: 0.62), Color(red: 0.62, green: 0.40, blue: 0.62),
                                    Color(red: 0.93, green: 0.62, blue: 0.58)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(red: 0.36, green: 0.42, blue: 0.98)).frame(width: 420).blur(radius: 120).offset(x: -160, y: -220).opacity(0.7)
            Circle().fill(Color(red: 0.98, green: 0.75, blue: 0.55)).frame(width: 360).blur(radius: 120).offset(x: 180, y: 260).opacity(0.6)
        }
    }
}

struct Pill: View {
    var symbol: String
    var text: String
    var color: Color = blue
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
            Text(text).font(.system(size: 15, weight: .medium)).foregroundStyle(ink)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Capsule().fill(Color(white: 0.16).opacity(0.8)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
    }
}

struct Title: View {
    var lines: [String]
    var size: CGFloat = 76
    var body: some View {
        VStack(alignment: .leading, spacing: -size * 0.12) {
            ForEach(lines, id: \.self) { Text($0).font(.system(size: size, weight: .bold)).foregroundStyle(ink) }
        }
        .kerning(-1.5)
    }
}

struct Brand: View {
    var body: some View {
        HStack(spacing: 18) {
            Image(nsImage: appIcon).resizable().frame(width: 76, height: 76)
            Text("Hovr").font(.system(size: 40, weight: .semibold)).foregroundStyle(ink)
        }
    }
}

// MARK: - Slides

struct HeroSlide: View {
    var body: some View {
        ZStack {
            Backdrop()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 34) {
                    Brand()
                    Title(lines: ["Capture it.", "Keep it", "in view."], size: 92)
                    Text("Pin anything on your screen above every window,\nor copy its text. One shortcut.")
                        .font(.system(size: 24)).foregroundStyle(inkSecondary).lineSpacing(5)
                    Keys(keys: ["⌥", "Tab"], size: 66)
                }
                .padding(.leading, 96)
                Spacer()
            }
            // An app window, the selection being made, and the card lifting out of it.
            AppWindow().frame(width: 640, height: 430).position(x: 1060, y: 400)
            SelectionGlow().frame(width: 300, height: 196).position(x: 1180, y: 432)
            ImageCard(width: 340, height: 222).rotationEffect(.degrees(-3)).position(x: 1170, y: 690)
            ModeBadge().position(x: 1350, y: 540)
        }
        .frame(width: canvas.width, height: canvas.height)
    }
}

struct StepCard<Art: View>: View {
    var number: String
    var title: String
    var text: String
    @ViewBuilder var art: Art
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack { art }.frame(width: 360, height: 250).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.10)))
            HStack(spacing: 12) {
                Text(number).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(Circle().fill(LinearGradient(colors: [blue, violet], startPoint: .top, endPoint: .bottom)))
                Text(title).font(.system(size: 26, weight: .semibold)).foregroundStyle(ink)
            }
            Text(text).font(.system(size: 17)).foregroundStyle(inkSecondary).lineSpacing(4).frame(width: 360, alignment: .leading)
        }
    }
}

struct HowSlide: View {
    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 56) {
                Title(lines: ["Select. It floats."], size: 64).frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .top, spacing: 44) {
                    StepCard(number: "1", title: "Press ⌥Tab", text: "The screen freezes. Drag around anything: a picture, a palette, a layout, a chart.") {
                        ZStack {
                            Color(white: 0.10)
                            Scene().opacity(0.9).padding(22).clipShape(RoundedRectangle(cornerRadius: 10))
                            SelectionGlow().frame(width: 170, height: 120).offset(x: 40, y: -6)
                            ModeBadge().offset(x: 150, y: 60)
                        }
                    }
                    StepCard(number: "2", title: "It stays on top", text: "Your selection becomes a card above every window, every Space and full-screen apps.") {
                        ZStack {
                            Color(white: 0.10)
                            AppWindow(title: "Design", picture: false).frame(width: 300, height: 200).scaleEffect(0.95).offset(x: -18, y: 12).opacity(0.85)
                            ImageCard(width: 190, height: 126).offset(x: 70, y: -40)
                        }
                    }
                    StepCard(number: "3", title: "Or copy the text", text: "Press Tab to switch to Text: the selection turns red and Hovr copies what it reads.") {
                        ZStack {
                            Color(white: 0.10)
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(["Order #20481", "Ship to: Rua das Flores, 120", "Total: R$ 349,90"], id: \.self) {
                                    Text($0).font(.system(size: 17, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                                }
                            }
                            .padding(14)
                            .overlay(SelectionGlow(color: textRed))
                            ModeBadge(text: true).offset(x: 150, y: 70)
                        }
                    }
                }
            }
            .padding(.horizontal, 96)
        }
        .frame(width: canvas.width, height: canvas.height)
    }
}

struct CardsSlide: View {
    var body: some View {
        ZStack {
            Backdrop(glows: [(violet, CGPoint(x: 0.15, y: 0.15), 600), (blue, CGPoint(x: 0.95, y: 0.6), 560), (deep, CGPoint(x: 0.5, y: 1.1), 560)])
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 30) {
                    Title(lines: ["Out of the way.", "One flick."], size: 70)
                    Text("Throw a card at the screen edge and it tucks away,\nleaving a thin tab. Click it and it slides back.")
                        .font(.system(size: 22)).foregroundStyle(inkSecondary).lineSpacing(5)
                    VStack(alignment: .leading, spacing: 12) {
                        Pill(symbol: "hand.draw", text: "Move with two fingers, throw, dock at the edge")
                        Pill(symbol: "plus.magnifyingglass", text: "Pinch to zoom, ⌥ + scroll for opacity")
                        Pill(symbol: "checklist", text: "Text cards with checklists and lists", color: textRed)
                        Pill(symbol: "text.viewfinder", text: "Extract the text from any image card")
                    }
                }
                .padding(.leading, 96)
                Spacer()
            }
            // A screen edge on the right, with a docked tab and its glow, a note and an image card.
            ZStack {
                Wallpaper()
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.10)))
                Text("screen edge").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                    .rotationEffect(.degrees(-90)).offset(x: 248, y: 30)
                NoteCard().rotationEffect(.degrees(-2)).offset(x: -130, y: -60)
                ImageCard(width: 300, height: 196).offset(x: 40, y: 150)
                // Docked tab at the edge, with the soft edge glow.
                LinearGradient(colors: [imageBlue.opacity(0.8), imageBlue.opacity(0)], startPoint: .trailing, endPoint: .leading)
                    .frame(width: 30, height: 230)
                    .mask(LinearGradient(colors: [.clear, .black, .black, .clear], startPoint: .top, endPoint: .bottom))
                    .offset(x: 265, y: -150)
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(LinearGradient(colors: [Color(red: 0.93, green: 0.55, blue: 0.47), Color(red: 0.45, green: 0.30, blue: 0.62)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 14, height: 150).offset(x: 273, y: -150)
            }
            .frame(width: 560, height: 680)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .position(x: 1110, y: 450)
        }
        .frame(width: canvas.width, height: canvas.height)
    }
}

struct RecentsSlide: View {
    let tiles: [AnyView] = [
        AnyView(Scene()), AnyView(LinearGradient(colors: [blue, violet], startPoint: .top, endPoint: .bottom)),
        AnyView(ZStack(alignment: .topLeading) { lemon; Text("☑︎ Palette\n○ Crop\n○ Send").font(.system(size: 11)).foregroundStyle(.black.opacity(0.75)).padding(8) }),
        AnyView(ZStack(alignment: .topLeading) { Color.white; Text("Order #20481\nShip to: Rua das Flores…").font(.system(size: 10)).foregroundStyle(.black.opacity(0.75)).padding(8) }),
        AnyView(Scene().scaleEffect(1.6)), AnyView(LinearGradient(colors: [Color(red: 0.98, green: 0.80, blue: 0.62), Color(red: 0.93, green: 0.45, blue: 0.47)], startPoint: .topLeading, endPoint: .bottomTrailing)),
    ]

    var body: some View {
        ZStack {
            Backdrop(glows: [(blue, CGPoint(x: 0.2, y: 0.85), 600), (violet, CGPoint(x: 0.55, y: 0.1), 520)])
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 30) {
                    Title(lines: ["Everything you", "captured."], size: 70)
                    Text("Recents slides in from the edge of the screen with every\nimage and text from the last days. Click one to pin it again.")
                        .font(.system(size: 22)).foregroundStyle(inkSecondary).lineSpacing(5)
                    HStack(spacing: 14) {
                        Keys(keys: ["⌃", "⌥", "H"], size: 54)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Pill(symbol: "folder", text: "Saved in a folder you choose, ~/Pictures/Hovr")
                        Pill(symbol: "calendar", text: "Kept for 3, 7, 14 or 30 days, or forever")
                        Pill(symbol: "speaker.wave.2", text: "Shutter sound, haptics, English and Portuguese")
                    }
                }
                .padding(.leading, 96)
                Spacer()
            }
            // The Recents panel on the right edge.
            ZStack(alignment: .topTrailing) {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.35), location: 0.4), .init(color: .black.opacity(0.65), location: 1)],
                               startPoint: .leading, endPoint: .trailing)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text("Recents").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        Text("2 active").font(.system(size: 15)).foregroundStyle(.white.opacity(0.45))
                    }
                    Text("Today, 24 November").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                    LazyVGrid(columns: [GridItem(.fixed(130), spacing: 14), GridItem(.fixed(130), spacing: 0)], spacing: 14) {
                        ForEach(0..<tiles.count, id: \.self) { i in
                            tiles[i].frame(width: 130, height: 130).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.15)))
                                .rotationEffect(.degrees([-1.2, 0.8, 0.4, -0.8, 1.0, -0.4][i]))
                                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                        }
                    }
                }
                .frame(width: 274, alignment: .leading)
                .padding(.top, 70).padding(.trailing, 44)
            }
            .frame(width: 520, height: canvas.height)
            .position(x: canvas.width - 260, y: canvas.height / 2)
        }
        .frame(width: canvas.width, height: canvas.height)
    }
}

// MARK: - Render

@MainActor func render<V: View>(_ view: V, _ path: String) {
    let r = ImageRenderer(content: view.environment(\.colorScheme, .dark))
    r.scale = 2
    guard let cg = r.cgImage else { fatalError("render failed: \(path)") }
    let rep = NSBitmapImageRep(cgImage: cg)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) \(cg.width)×\(cg.height)")
}

MainActor.assumeIsolated {
    render(HeroSlide(), "Promo/01-hero.png")
    render(HowSlide(), "Promo/02-how-it-works.png")
    render(CardsSlide(), "Promo/03-cards.png")
    render(RecentsSlide(), "Promo/04-recents.png")
}
