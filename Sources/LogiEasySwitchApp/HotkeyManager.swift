import AppKit
import Carbon.HIToolbox

struct Shortcut: Codable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String

    var displayLabel: String {
        var value = ""
        if modifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        if modifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if modifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if modifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        return value + shortcutKeyLabel(keyCode: keyCode, fallback: label)
    }
}

func shortcutKeyLabel(keyCode: UInt32, fallback: String) -> String {
    let names: [UInt32: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
        97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
    ]
    return names[keyCode] ?? fallback
}

final class HotkeyManager {
    private var references: [EventHotKeyRef?] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1

    init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, eventRef, userData in
            guard let eventRef, let userData else { return noErr }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(eventRef, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr else { return status }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.actions[identifier.id]?()
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func replace(with bindings: [String: Shortcut], action: @escaping (String) -> Void) {
        references.forEach { reference in if let reference { UnregisterEventHotKey(reference) } }
        references = []
        actions = [:]
        nextID = 1
        for (target, shortcut) in bindings {
            let id = nextID
            nextID += 1
            let hotkeyID = EventHotKeyID(signature: OSType(0x4C455357), id: id) // "LESW"
            var ref: EventHotKeyRef?
            guard RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotkeyID, GetApplicationEventTarget(), 0, &ref) == noErr else { continue }
            references.append(ref)
            actions[id] = { action(target) }
        }
    }
}

func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var result: UInt32 = 0
    if flags.contains(.command) { result |= UInt32(cmdKey) }
    if flags.contains(.option) { result |= UInt32(optionKey) }
    if flags.contains(.control) { result |= UInt32(controlKey) }
    if flags.contains(.shift) { result |= UInt32(shiftKey) }
    return result
}
