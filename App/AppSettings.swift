import AppKit
import ServiceManagement

/// What a capture does with the selected area.
enum CaptureMode: Int, CaseIterable, Identifiable {
    /// Copies the image and pins it as a floating card.
    case image = 0
    /// Reads the text in the area and copies it.
    case text = 1
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .image: String(localized: "Image")
        case .text: String(localized: "Text")
        }
    }

    var symbol: String {
        switch self {
        case .image: "photo"
        case .text: "text.viewfinder"
        }
    }

    var toggled: CaptureMode { self == .image ? .text : .image }

    /// Each mode has its own colour, so the selection shows which one is on.
    var color: NSColor { self == .image ? .systemBlue : .systemRed }
}

/// Interface language. English is the default; Portuguese is optional.
enum AppLanguage: String, CaseIterable, Identifiable {
    case en, pt
    var id: String { rawValue }
    /// Shown in its own language, so anyone can find theirs.
    var label: String { self == .en ? "English" : "Português" }
    var localeCode: String { self == .en ? "en" : "pt-BR" }

    static var stored: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .en
    }
}

/// Global shortcuts (work in any app).
enum HotkeyAction: String, CaseIterable, Identifiable {
    case capture, recents, toggleCards
    var id: String { rawValue }

    var title: String {
        switch self {
        case .capture: String(localized: "Capture")
        case .recents: String(localized: "Recents")
        case .toggleCards: String(localized: "Hide or show cards")
        }
    }

    var symbol: String {
        switch self {
        case .capture: "viewfinder"
        case .recents: "square.grid.2x2.fill"
        case .toggleCards: "eye"
        }
    }

    var defaultsKey: String { self == .capture ? "shortcut" : "shortcut.\(rawValue)" }

    var defaultShortcut: Shortcut {
        switch self {
        case .capture: .defaultCapture
        case .recents: Shortcut(keyCode: 4, modifiers: Shortcut.control | Shortcut.option)      // ⌃⌥H
        case .toggleCards: Shortcut(keyCode: 9, modifiers: Shortcut.control | Shortcut.option)  // ⌃⌥V
        }
    }
}

/// Everything the user can change, stored in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var shortcuts: [HotkeyAction: Shortcut] = [:] {
        didSet {
            for action in HotkeyAction.allCases {
                if let s = shortcuts[action], let data = try? JSONEncoder().encode(s) {
                    defaults.set(data, forKey: action.defaultsKey)
                } else {
                    defaults.set(Data(), forKey: action.defaultsKey) // empty = no shortcut on purpose
                }
            }
            applyShortcuts()
        }
    }
    /// Shortcuts another app already holds.
    @Published private(set) var takenShortcuts: Set<HotkeyAction> = []

    /// The capture shortcut (shown in menus).
    var shortcut: Shortcut? { shortcuts[.capture] }

    func binding(for action: HotkeyAction) -> Shortcut? { shortcuts[action] }

    /// Mode the selection starts in.
    @Published var startMode: CaptureMode { didSet { defaults.set(startMode.rawValue, forKey: "startMode") } }
    /// Image mode also puts the image on the clipboard.
    @Published var copyImage: Bool { didSet { defaults.set(copyImage, forKey: "copyImage") } }
    /// Image mode pins the image on screen.
    @Published var pinImage: Bool { didSet { defaults.set(pinImage, forKey: "pinImage") } }
    /// Clicking a window during a selection captures that window (Space switches it for one selection).
    @Published var clickToCaptureWindow: Bool { didSet { defaults.set(clickToCaptureWindow, forKey: "clickToCaptureWindow") } }
    /// Leaves open cards out of the frozen screen (and so out of new captures).
    @Published var hideCardsDuringCapture: Bool { didSet { defaults.set(hideCardsDuringCapture, forKey: "hideCardsDuringCapture") } }
    /// How long captures stay in Recents; 0 keeps them forever.
    @Published var historyDays: Int {
        didSet {
            defaults.set(historyDays, forKey: "historyDays")
            History.shared.prune()
        }
    }
    /// Two-finger scroll on a trackpad moves a card (a mouse wheel always zooms).
    @Published var scrollMovesCard: Bool { didSet { defaults.set(scrollMovesCard, forKey: "scrollMovesCard") } }
    /// Cards open again after Hovr relaunches.
    @Published var restoreCards: Bool { didSet { defaults.set(restoreCards, forKey: "restoreCards") } }

    // Cards
    /// New notes: one fixed colour, or a random one from the palette.
    @Published var noteColorRandom: Bool { didSet { defaults.set(noteColorRandom, forKey: "noteColorRandom") } }
    @Published var noteColor: String { didSet { defaults.set(noteColor, forKey: "noteColor") } }
    /// How hard a flick must be to throw a card: 0 easy, 1 normal, 2 firm.
    @Published var throwIntensity: Int { didSet { defaults.set(throwIntensity, forKey: "throwIntensity") } }
    /// Capture on every screen at once (off: only the screen with the pointer).
    @Published var multipleDisplays: Bool { didSet { defaults.set(multipleDisplays, forKey: "multipleDisplays") } }
    /// When a display goes away: 0 cards move to the main display as they are; 1 they come back undocked.
    @Published var displayDisconnect: Int { didSet { defaults.set(displayDisconnect, forKey: "displayDisconnect") } }
    /// Notes: double-click to edit (off: click once to select, again to edit).
    @Published var doubleClickToEdit: Bool { didSet { defaults.set(doubleClickToEdit, forKey: "doubleClickToEdit") } }
    /// A card left partly off the screen stays there (off: it slides back onto the screen).
    @Published var hangPastEdge: Bool { didSet { defaults.set(hangPastEdge, forKey: "hangPastEdge") } }

    func newNoteColor() -> String {
        noteColorRandom ? (NoteColor.palette.filter { $0 != "#1F1F1F" && $0 != "#FFFFFF" }.randomElement() ?? noteColor) : noteColor
    }

    /// Flick speed (pt/s) that counts as a throw, and how fast a thrown card slows down.
    var throwThreshold: CGFloat { [700, 1100, 1600][min(max(throwIntensity, 0), 2)] }
    var throwFriction: Double { [4.2, 5.5, 7][min(max(throwIntensity, 0), 2)] }

    // Sound & haptics
    @Published var soundEffects: Bool { didSet { defaults.set(soundEffects, forKey: "soundEffects") } }
    @Published var shutterSound: Bool { didSet { defaults.set(shutterSound, forKey: "shutterSound") } }
    @Published var whooshSound: Bool { didSet { defaults.set(whooshSound, forKey: "whooshSound") } }
    @Published var haptics: Bool { didSet { defaults.set(haptics, forKey: "haptics") } }

    @Published var language: AppLanguage { didSet { defaults.set(language.rawValue, forKey: "language") } }
    @Published var autoUpdate: Bool { didSet { defaults.set(autoUpdate, forKey: "autoUpdate") } }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Hovr: launch at login: \(error)")
            }
        }
    }

    /// The language the running process was started with; a different choice needs a relaunch.
    let launchedLanguage = AppLanguage.stored

    private static let boolDefaults: [String: Any] = [
        "copyImage": true, "pinImage": true, "scrollMovesCard": true, "restoreCards": true, "autoUpdate": false,
        "hideCardsDuringCapture": true, "clickToCaptureWindow": false,
        "soundEffects": true, "shutterSound": true, "whooshSound": true, "haptics": true,
        "noteColorRandom": false, "multipleDisplays": true, "doubleClickToEdit": true, "hangPastEdge": false,
    ]

    private init() {
        defaults.register(defaults: Self.boolDefaults.merging(["startMode": CaptureMode.image.rawValue, "historyDays": 7,
                                                               "noteColor": NoteColor.defaultHex, "throwIntensity": 1,
                                                               "displayDisconnect": 0]) { a, _ in a })
        var loaded: [HotkeyAction: Shortcut] = [:]
        for action in HotkeyAction.allCases {
            if let data = defaults.data(forKey: action.defaultsKey) {
                if !data.isEmpty { loaded[action] = (try? JSONDecoder().decode(Shortcut.self, from: data)) ?? action.defaultShortcut }
            } else {
                loaded[action] = action.defaultShortcut
            }
        }
        shortcuts = loaded
        startMode = CaptureMode(rawValue: defaults.integer(forKey: "startMode")) ?? .image
        copyImage = defaults.bool(forKey: "copyImage")
        pinImage = defaults.bool(forKey: "pinImage")
        historyDays = max(0, defaults.integer(forKey: "historyDays"))
        hideCardsDuringCapture = defaults.bool(forKey: "hideCardsDuringCapture")
        clickToCaptureWindow = defaults.bool(forKey: "clickToCaptureWindow")
        scrollMovesCard = defaults.bool(forKey: "scrollMovesCard")
        restoreCards = defaults.bool(forKey: "restoreCards")
        soundEffects = defaults.bool(forKey: "soundEffects")
        shutterSound = defaults.bool(forKey: "shutterSound")
        whooshSound = defaults.bool(forKey: "whooshSound")
        haptics = defaults.bool(forKey: "haptics")
        noteColorRandom = defaults.bool(forKey: "noteColorRandom")
        noteColor = defaults.string(forKey: "noteColor") ?? NoteColor.defaultHex
        throwIntensity = defaults.integer(forKey: "throwIntensity")
        multipleDisplays = defaults.bool(forKey: "multipleDisplays")
        displayDisconnect = defaults.integer(forKey: "displayDisconnect")
        doubleClickToEdit = defaults.bool(forKey: "doubleClickToEdit")
        hangPastEdge = defaults.bool(forKey: "hangPastEdge")
        language = .stored
        autoUpdate = defaults.bool(forKey: "autoUpdate")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Every setting back to its default (captures, cards and the captures folder stay).
    func resetToDefaults() {
        var all: [HotkeyAction: Shortcut] = [:]
        for a in HotkeyAction.allCases { all[a] = a.defaultShortcut }
        shortcuts = all
        startMode = .image
        copyImage = true
        pinImage = true
        historyDays = 7
        scrollMovesCard = true
        restoreCards = true
        autoUpdate = false
        hideCardsDuringCapture = true
        clickToCaptureWindow = false
        soundEffects = true
        shutterSound = true
        whooshSound = true
        haptics = true
        noteColorRandom = false
        noteColor = NoteColor.defaultHex
        throwIntensity = 1
        multipleDisplays = true
        displayDisconnect = 0
        doubleClickToEdit = true
        hangPastEdge = false
        UserDefaults.standard.removeObject(forKey: "selectionHintCount")
    }

    func applyShortcuts() {
        takenShortcuts = HotkeyCenter.shared.register(shortcuts)
    }

    /// 0 = never delete.
    static let historyChoices = [3, 7, 14, 30, 0]
}

// MARK: - Sounds and haptics

@MainActor
enum Feedback {
    private static let systemSounds = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/"
    private static var shutterPlayer: NSSound?
    private static var whooshPlayer: NSSound?

    /// The camera shutter, when a capture is taken (image or text).
    static func shutter() {
        let s = AppSettings.shared
        guard s.soundEffects, s.shutterSound else { return }
        if shutterPlayer == nil { shutterPlayer = NSSound(contentsOfFile: systemSounds + "Screen Capture.aif", byReference: true) }
        shutterPlayer?.stop()
        shutterPlayer?.play()
    }

    /// A soft whoosh when a card is thrown or docks at the edge.
    static func whoosh() {
        let s = AppSettings.shared
        guard s.soundEffects, s.whooshSound else { return }
        if whooshPlayer == nil {
            whooshPlayer = NSSound(contentsOfFile: systemSounds + "SentMessage.caf", byReference: true)
            whooshPlayer?.volume = 0.5
        }
        whooshPlayer?.stop()
        whooshPlayer?.play()
    }

    /// A light tap on the trackpad (card docks, capture mode changes).
    static func tap() {
        guard AppSettings.shared.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
