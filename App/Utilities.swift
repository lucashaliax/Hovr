import AppKit
import Vision

// MARK: - Text recognition

enum OCR {
    /// Reads the text in an image, line by line, in reading order. Runs off the main thread.
    static func recognize(_ image: CGImage) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
            } catch {
                return nil
            }
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        }.value
    }
}

// MARK: - Clipboard

enum Pasteboard {
    static func copy(image: CGImage, scale: CGFloat) {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let pb = NSPasteboard.general
        pb.clearContents()
        if let png = rep.representation(using: .png, properties: [:]) {
            pb.setData(png, forType: .png)
        }
        if let tiff = rep.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
    }

    static func copy(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

// MARK: - On-screen confirmation

/// A small rounded message near the bottom of the screen with the pointer, gone after a moment.
@MainActor
final class HUD {
    static let shared = HUD()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ message: String, symbol: String) {
        hideWork?.cancel()
        panel?.orderOut(nil)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        icon.contentTintColor = .labelColor
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 18)

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 20
        effect.layer?.masksToBounds = true
        effect.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        let size = stack.fittingSize

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? .zero
        let p = NSPanel(contentRect: NSRect(x: vf.midX - size.width / 2, y: vf.minY + 80, width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = effect
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
        panel = p

        let work = DispatchWorkItem { [weak self, weak p] in
            guard let p else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }) {
                MainActor.assumeIsolated {
                    p.orderOut(nil)
                    if self?.panel === p { self?.panel = nil }
                }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }
}

// MARK: - Menu animation

/// The soft way menus appear: growing out of the point they come from with a gentle spring while fading in,
/// and shrinking a little while fading out. Runs on a wrapper view's layer (never the window's content view).
@MainActor
enum PopAnimation {
    /// A scale around `anchor` (0…1 in the view, y up). View layers scale around their bottom-left corner,
    /// so the pivot is moved there and back.
    private static func scale(_ k: CGFloat, in b: CGRect, anchor: CGPoint) -> CATransform3D {
        let ax = b.width * anchor.x, ay = b.height * anchor.y
        var t = CATransform3DMakeTranslation(ax, ay, 0)
        t = CATransform3DScale(t, k, k, 1)
        return CATransform3DTranslate(t, -ax, -ay, 0)
    }

    static func show(_ view: NSView, anchor: CGPoint) {
        guard let layer = view.layer else { return }
        layer.removeAllAnimations()
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: scale(0.8, in: view.bounds, anchor: anchor))
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.mass = 1
        spring.stiffness = 280
        spring.damping = 22
        spring.duration = spring.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.2
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
        layer.add(spring, forKey: "popScale")
        layer.add(fade, forKey: "popFade")
    }

    static func hide(_ view: NSView, anchor: CGPoint, completion: @escaping () -> Void) {
        guard let layer = view.layer else { completion(); return }
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? CATransform3DIdentity)
        shrink.toValue = NSValue(caTransform3D: scale(0.92, in: view.bounds, anchor: anchor))
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? 1
        fade.toValue = 0
        for a in [shrink, fade] {
            a.duration = 0.15
            a.timingFunction = CAMediaTimingFunction(name: .easeIn)
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                completion()
                layer.removeAllAnimations()
            }
        }
        layer.add(shrink, forKey: "popScale")
        layer.add(fade, forKey: "popFade")
        CATransaction.commit()
    }
}

// MARK: - Diagnostics

/// A small text log at ~/Library/Logs/Hovr/diagnostics.log (kept under 200 KB), for problems that need
/// the user's hands to reproduce (gestures, permissions).
enum Diag {
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Hovr")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("diagnostics.log")
    }()
    private static let queue = DispatchQueue(label: "hovr.diag")

    static func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 200_000 {
                try? FileManager.default.removeItem(at: url)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

// MARK: - Capture flash

/// A quick white flash over the captured area, so it's obvious the capture was taken.
@MainActor
enum SelectionFlash {
    static func show(_ rect: NSRect) {
        let w = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.55).cgColor
        v.layer?.cornerRadius = 12
        w.contentView = v
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().alphaValue = 0
        }) {
            MainActor.assumeIsolated { w.orderOut(nil) }
        }
    }
}
