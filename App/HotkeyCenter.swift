import Carbon.HIToolbox
import Foundation

/// Global shortcuts through Carbon's `RegisterEventHotKey`.
/// Unlike an event tap, this needs no Accessibility or Input Monitoring permission.
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    var onHotkey: ((HotkeyAction) -> Void)?

    private let signature: OSType = 0x434C_4E45 // 'CLNE'
    private var refs: [EventHotKeyRef] = []
    private var actionsByID: [UInt32: HotkeyAction] = [:]
    private var handlerRef: EventHandlerRef?
    private var current: [HotkeyAction: Shortcut] = [:]
    private(set) var isSuspended = false

    private init() {}

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard status == noErr else { return status }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            if let action = center.actionsByID[hk.id] {
                DispatchQueue.main.async { center.onHotkey?(action) }
            }
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)
    }

    /// Registers the shortcuts, replacing the previous set. Returns those another app already uses.
    @discardableResult
    func register(_ shortcuts: [HotkeyAction: Shortcut]) -> Set<HotkeyAction> {
        installHandlerIfNeeded()
        unregisterAll()
        current = shortcuts
        guard !isSuspended else { return [] }
        var taken = Set<HotkeyAction>()
        for (i, action) in HotkeyAction.allCases.enumerated() {
            guard let s = shortcuts[action], s.isValidGlobal else { continue }
            let id = UInt32(i + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(s.keyCode, s.modifiers, EventHotKeyID(signature: signature, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actionsByID[id] = action
            } else {
                taken.insert(action)
            }
        }
        return taken
    }

    private func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actionsByID.removeAll()
    }

    /// While the user records a new shortcut, the current ones must not fire.
    func suspend() {
        isSuspended = true
        unregisterAll()
    }

    func resume() {
        isSuspended = false
        register(current)
    }
}
