import AppKit
import SwiftUI
import UserNotifications

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private let settings = AppSettings.shared

    static func main() {
        Migration.run()
        applyInterfaceLanguage()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        app.run()
    }

    /// English unless the user chose Portuguese. Set before anything reads the bundle's
    /// localizations, so it applies to this launch without restarting the process.
    private static func applyInterfaceLanguage() {
        let wanted = [AppLanguage.stored.localeCode]
        let key = "AppleLanguages" as CFString
        let current = CFPreferencesCopyAppValue(key, kCFPreferencesCurrentApplication) as? [String]
        guard current != wanted else { return }
        CFPreferencesSetAppValue(key, wanted as CFArray, kCFPreferencesCurrentApplication)
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        UserDefaults.standard.set(wanted, forKey: "AppleLanguages")
    }

    static func relaunch() {
        CardManager.shared.saveOpenCards()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        HotkeyCenter.shared.onHotkey = { action in
            switch action {
            case .capture: CaptureController.shared.hotkeyPressed()
            case .recents: RecentsPanelController.shared.toggle()
            case .toggleCards: CardManager.shared.toggleVisibility()
            }
        }
        settings.applyShortcuts()
        setUpStatusItem()
        CardManager.shared.restoreOpenCards()
        Diag.log("launch \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "") — Input Monitoring: \(CGPreflightListenEventAccess()), Screen Recording: \(CGPreflightScreenCaptureAccess())")
        CardManager.shared.installGestureMonitors()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CardManager.shared.screensChanged() }
        }
        UNUserNotificationCenter.current().delegate = self
        Updater.shared.onOpenRequested = { [weak self] in self?.showSettings(.about) }

        // `open -a Hovr --args -HovrRunUpdate YES` checks and installs the latest release without asking.
        if UserDefaults.standard.bool(forKey: "HovrRunUpdate") {
            Task {
                if let release = await Updater.shared.check() {
                    NSLog("Hovr: installing \(release.version)")
                    Updater.shared.install(release)
                } else {
                    NSLog("Hovr: no update (\(String(describing: Updater.shared.state)))")
                }
            }
            return
        }
        if settings.autoUpdate { Updater.shared.checkInBackgroundIfDue() }

        // `open Hovr.app --args -HovrPreview menu|settings|capture` opens one piece of UI (to check its look).
        switch UserDefaults.standard.string(forKey: "HovrPreview") {
        case "menu":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let b = self.statusItem?.button { MenuPanelController.shared.open(from: b) }
            }
        case "settings": showSettings(.general)
        case "advanced": showSettings(.advanced)
        case "shortcuts": showSettings(.shortcuts)
        case "sound": showSettings(.sound)
        case "cards": showSettings(.cards)
        case "glow": EdgeGlow.shared.update(for: NSRect(x: 0, y: 400, width: 300, height: 200), edge: .left, strength: 1)
        case "pinchtest":
            // 300 pinch steps out and 300 back in on the latest image card; logs how far its shape drifted.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard let e = History.shared.entries.first(where: { !$0.note && !$0.isTextCapture }) else { return }
                CardManager.shared.pin(e.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    guard let card = CardManager.shared.card(e.id), let img = card.image else { return }
                    let start = card.frame
                    card.host.handleMagnify(0, phase: .began)
                    for _ in 0..<300 { card.host.handleMagnify(0.004, phase: .changed) }
                    card.host.handleMagnify(0, phase: .ended)
                    let big = card.frame
                    card.host.handleMagnify(0, phase: .began)
                    for _ in 0..<300 { card.host.handleMagnify(-0.0015, phase: .changed) }
                    card.host.handleMagnify(0, phase: .ended)
                    let f = card.frame
                    let ia = Double(img.width) / Double(img.height)
                    Diag.log("pinchtest image aspect \(ia) start \(start.size) big \(big.size) end \(f.size) end aspect \(Double(f.width / f.height))")
                }
            }
        case "askinput":
            // Adds Hovr to Input Monitoring and shows the system prompt.
            if !CGRequestListenEventAccess(),
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(url)
            }
        case "capture": CaptureController.shared.start()
        case "capturetest":
            // A wide 500×120 selection: the card must still come out in the standard shape.
            CaptureController.shared.start(mode: .image)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                CaptureController.shared.finishForTest(NSRect(x: 300, y: 300, width: 500, height: 120))
            }
        case "recents": DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { RecentsPanelController.shared.open() }
        case "note":
            CardManager.shared.newNote(at: NSPoint(x: 400, y: 600))
            if let card = CardManager.shared.cards.last, let note = card.host.subviews.compactMap({ $0 as? NoteCardView }).first {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { note.fillSample() }
            }
        case "pin", "cardmenu", "dock":
            // Pins the latest image capture; "cardmenu" also opens its ⋯ menu, "dock" docks it on the left.
            let preview = UserDefaults.standard.string(forKey: "HovrPreview")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard let e = History.shared.entries.first(where: { !$0.note && !$0.isTextCapture }) else { return }
                CardManager.shared.pin(e.id)
                guard let card = CardManager.shared.card(e.id) else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if preview == "cardmenu" {
                        let f = card.frame
                        CardMenuController.shared.show(for: card, below: NSRect(x: f.maxX - 28, y: f.maxY - 28, width: 22, height: 22))
                    } else if preview == "dock" {
                        card.dock(.left, restoreTo: card.frame)
                    }
                }
            }
        default: break
        }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "HovrDemo") { runDemo() }
        #endif
    }

    #if DEBUG
    /// `open Hovr.app --args -HovrDemo YES`: pins a generated image with text and logs its OCR,
    /// to check cards, history and text reading without Screen Recording.
    private func runDemo() {
        let size = NSSize(width: 420, height: 220)
        let img = NSImage(size: size, flipped: false) { r in
            NSColor(calibratedRed: 0.99, green: 0.95, blue: 0.88, alpha: 1).setFill()
            r.fill()
            ("Reference card\nCopy this text 123" as NSString).draw(
                at: NSPoint(x: 28, y: 70),
                withAttributes: [.font: NSFont.systemFont(ofSize: 36, weight: .bold), .foregroundColor: NSColor.black])
            return true
        }
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let entry = History.shared.add(image: cg, scale: 2, text: nil)
        CardManager.shared.pin(entry: entry, image: cg)
        Task {
            let t = await History.shared.text(for: entry.id) ?? ""
            NSLog("Hovr demo OCR: \(t.replacingOccurrences(of: "\n", with: " | "))")
        }
    }
    #endif

    func applicationWillTerminate(_ notification: Notification) {
        CardManager.shared.saveOpenCards()
    }

    /// Opening the app again from Finder shows Settings, since it has no Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(.general)
        return false
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = HovrGlyph.menuBarImage
            button.image?.accessibilityDescription = "Hovr"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            MenuPanelController.shared.statusButton = button
        }
        statusItem = item
        MenuPanelController.shared.actions = MenuActions(
            captureImage: { CaptureController.shared.start(mode: .image) },
            captureText: { CaptureController.shared.start(mode: .text) },
            recents: { RecentsPanelController.shared.open() },
            settings: { [weak self] in self?.showSettings(.general) },
            closeAllCards: { CardManager.shared.closeAll() },
            quit: { NSApp.terminate(nil) })
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        MenuPanelController.shared.toggle(from: sender)
    }

    func showHistory() { RecentsPanelController.shared.open() }

    func showSettings(_ pane: SettingsPane) {
        SettingsSelection.shared.pane = pane
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = String(localized: "Hovr Settings")
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.isOpaque = false
            w.backgroundColor = .clear
            w.contentView = NSHostingView(rootView: SettingsView())
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Notifications (update available)

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in self.showSettings(.about) }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
