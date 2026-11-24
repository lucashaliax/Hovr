import Foundation

/// A keyboard shortcut stored as a virtual key code plus Carbon modifier flags,
/// which is exactly what `RegisterEventHotKey` takes.
struct Shortcut: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    // Carbon modifier bits (Events.h), repeated here so Shared code needs no Carbon import.
    static let cmd: UInt32 = 1 << 8
    static let shift: UInt32 = 1 << 9
    static let option: UInt32 = 1 << 11
    static let control: UInt32 = 1 << 12

    /// A global shortcut needs at least one of ⌘ ⌃ ⌥, otherwise it would swallow plain typing.
    var isValidGlobal: Bool {
        modifiers & (Self.cmd | Self.control | Self.option) != 0
    }

    var modifierSymbols: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.cmd != 0 { s += "⌘" }
        return s
    }
}

extension Shortcut {
    /// ⌥Tab (kVK_Tab = 48): the capture shortcut.
    static let defaultCapture = Shortcut(keyCode: 48, modifiers: option)
}
