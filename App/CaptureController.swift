import AppKit
import ScreenCaptureKit

/// Runs one capture: freezes every screen, lets the user pick an area or a window,
/// then copies the image (and pins it) or reads and copies its text.
@MainActor
final class CaptureController {
    static let shared = CaptureController()

    private var overlays: [SelectionOverlayWindow] = []
    private var previousApp: NSRunningApplication?
    private var starting = false

    /// Current mode while the selection is on screen; the shortcut or Tab switches it.
    private(set) var mode: CaptureMode = .image {
        didSet {
            overlays.forEach { $0.selectionView.modeChanged() }
            if isActive && mode != oldValue { Feedback.tap() }
        }
    }

    var isActive: Bool { !overlays.isEmpty }

    /// Pressing the shortcut again while selecting switches between Image and Text.
    func hotkeyPressed() {
        if isActive { toggleMode() } else { start() }
    }

    func toggleMode() { mode = mode.toggled }
    func setMode(_ m: CaptureMode) { mode = m }

    func start(mode startMode: CaptureMode? = nil) {
        guard !isActive, !starting else { return }
        guard ensurePermission() else { return }
        starting = true
        mode = startMode ?? AppSettings.shared.startMode
        previousApp = NSWorkspace.shared.frontmostApplication
        Task {
            defer { starting = false }
            let shots: [(NSScreen, CGImage)]
            do {
                shots = try await Self.captureScreens()
            } catch {
                NSLog("Hovr: capture failed: \(error)")
                HUD.shared.show(String(localized: "Couldn't capture the screen"), symbol: "exclamationmark.triangle")
                return
            }
            let windows = Self.visibleWindowFrames()
            for (screen, image) in shots {
                let w = SelectionOverlayWindow(screen: screen, image: image, windows: windows, controller: self)
                overlays.append(w)
            }
            NSApp.activate(ignoringOtherApps: true)
            let mouse = NSEvent.mouseLocation
            for w in overlays { w.orderFrontRegardless() }
            (overlays.first { $0.frame.contains(mouse) } ?? overlays.first)?.makeKey()
        }
    }

    func cancel() {
        close()
        restoreFocus()
    }

    private func close() {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
    }

    private func restoreFocus() {
        // Give the keyboard back to the app the user was in.
        if let previousApp, previousApp != NSRunningApplication.current { previousApp.activate() }
        previousApp = nil
    }

    /// Called by an overlay when the user finished a selection (rect in global screen points).
    func finish(rect: NSRect, on overlay: SelectionOverlayWindow, polygon: [NSPoint]? = nil) {
        guard let image = overlay.crop(rect, polygon: polygon) else { cancel(); return }
        let finalMode = mode
        let source = previousApp?.bundleIdentifier
        close()
        restoreFocus()
        Feedback.shutter()
        let scale = overlay.screen?.backingScaleFactor ?? 2

        switch finalMode {
        case .image:
            let settings = AppSettings.shared
            if settings.copyImage { Pasteboard.copy(image: image, scale: scale) }
            let entry = History.shared.add(image: image, scale: scale, text: nil, sourceApp: source)
            if settings.pinImage {
                CardManager.shared.pin(entry: entry, image: image, from: rect)
            } else {
                HUD.shared.show(String(localized: "Image copied"), symbol: "photo.on.rectangle")
            }
        case .text:
            Task {
                let text = await OCR.recognize(image)
                History.shared.add(image: image, scale: scale, text: text ?? "", sourceApp: source)
                if let text, !text.isEmpty {
                    Pasteboard.copy(text: text)
                    HUD.shared.show(String(localized: "Text copied"), symbol: "doc.on.clipboard")
                } else {
                    HUD.shared.show(String(localized: "No text found"), symbol: "text.magnifyingglass")
                }
            }
        }
    }

    /// Finishes the open selection with `rect` (used by `-HovrPreview capturetest`).
    func finishForTest(_ rect: NSRect) {
        guard let o = overlays.first else { return }
        finish(rect: rect, on: o)
    }

    /// Text mode, clicked without selecting: an empty note there.
    func createNote(at point: NSPoint) {
        close()
        restoreFocus()
        CardManager.shared.newNote(at: point)
    }

    // MARK: Permission

    private func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        // Shows the system prompt the first time; afterwards it only adds Hovr to the list.
        CGRequestScreenCaptureAccess()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "Allow Screen Recording")
        alert.informativeText = String(localized: "Hovr needs Screen Recording to capture the area you select. Turn on Hovr in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen Hovr.")
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    // MARK: Screens and windows

    /// One full-resolution image per screen, taken before any overlay appears.
    private static func captureScreens() async throws -> [(NSScreen, CGImage)] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var result: [(NSScreen, CGImage)] = []
        let onlyPointer = await MainActor.run { !AppSettings.shared.multipleDisplays }
        let mouse = await MainActor.run { NSEvent.mouseLocation }
        for screen in NSScreen.screens where !onlyPointer || screen.frame.contains(mouse) || NSScreen.screens.count == 1 {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { continue }
            // Open cards can be left out of the frozen screen.
            let hide = await MainActor.run { AppSettings.shared.hideCardsDuringCapture }
            let mine = hide ? content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier } : []
            let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            config.width = Int(screen.frame.width * scale)
            config.height = Int(screen.frame.height * scale)
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            result.append((screen, image))
        }
        return result
    }

    /// Frames of normal windows on screen, front to back, in Cocoa global coordinates.
    private static func visibleWindowFrames() -> [NSRect] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let me = ProcessInfo.processInfo.processIdentifier
        return info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
                  width > 40, height > 40 else { return nil }
            return NSRect(x: x, y: primaryHeight - y - height, width: width, height: height)
        }
    }
}
