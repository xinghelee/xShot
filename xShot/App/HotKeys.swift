import AppKit
import Carbon.HIToolbox

extension Notification.Name {
    static let hotKeysChanged = Notification.Name("xShot.hotKeysChanged")
}

enum HotKeyAction: String, CaseIterable, Identifiable {
    case area, window, fullscreen, scroll, ocr, record, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .area: "截取区域"
        case .window: "截取窗口"
        case .fullscreen: "截取全屏"
        case .scroll: "滚动长截图"
        case .ocr: "识别文字 (OCR)"
        case .record: "录制屏幕 / 停止录制"
        case .history: "打开截图历史"
        }
    }

    /// Mirrors CleanShot's "Use System Default Shortcuts": ⇧⌘3 / ⇧⌘4 / ⇧⌘5.
    /// Window capture has no default; press Space during area selection instead.
    var defaultCombo: KeyCombo? {
        let mods = UInt32(cmdKey | shiftKey)
        switch self {
        case .area: return KeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: mods)
        case .window, .history: return nil
        case .fullscreen: return KeyCombo(keyCode: UInt32(kVK_ANSI_3), modifiers: mods)
        case .scroll: return KeyCombo(keyCode: UInt32(kVK_ANSI_6), modifiers: mods)
        case .ocr: return KeyCombo(keyCode: UInt32(kVK_ANSI_2), modifiers: mods)
        case .record: return KeyCombo(keyCode: UInt32(kVK_ANSI_5), modifiers: mods)
        }
    }

    private var storageKey: String { "hotkey." + rawValue }

    /// nil means the user cleared the shortcut.
    var combo: KeyCombo? {
        get {
            guard let data = UserDefaults.standard.data(forKey: storageKey) else { return defaultCombo }
            return try? JSONDecoder().decode(KeyCombo.self, from: data)
        }
        nonmutating set {
            let data = newValue.flatMap { try? JSONEncoder().encode($0) } ?? Data()
            UserDefaults.standard.set(data, forKey: storageKey)
            NotificationCenter.default.post(name: .hotKeysChanged, object: nil)
        }
    }
}

struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask (cmdKey, optionKey, …).
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        var m: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        modifiers = m
    }

    var nsModifiers: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        return f
    }

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    var menuKeyEquivalent: String? {
        guard Self.specialKeys[Int(keyCode)] == nil else { return nil }
        let name = Self.keyName(keyCode)
        return name.count == 1 ? name.lowercased() : nil
    }

    private static let specialKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_DownArrow: "↓", kVK_UpArrow: "↑",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
    ]

    static func keyName(_ code: UInt32) -> String {
        if let special = specialKeys[Int(code)] { return special }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var onAction: ((HotKeyAction) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: HotKeyAction] = [:]
    private var handlerInstalled = false

    func registerAll() {
        unregisterAll()
        installHandlerIfNeeded()
        SystemScreenshotShortcuts.yield(to: HotKeyAction.allCases.compactMap(\.combo))
        for (index, action) in HotKeyAction.allCases.enumerated() {
            guard let combo = action.combo else { continue }
            let id = EventHotKeyID(signature: OSType(0x7853_6874), id: UInt32(index + 1))
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actions[id.id] = action
            } else {
                NSLog("xShot: failed to register hotkey \(combo.display) for \(action.rawValue): \(status)")
            }
        }
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }

    fileprivate func fire(_ id: UInt32) {
        if let action = actions[id] { onAction?(action) }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &spec, nil, nil)
    }
}

private nonisolated func hotKeyHandler(_: EventHandlerCallRef?, _ event: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return status }
    let hotKeyID = id.id
    DispatchQueue.main.async {
        MainActor.assumeIsolated { HotKeyCenter.shared.fire(hotKeyID) }
    }
    return noErr
}

/// Temporarily turns off the macOS screenshot shortcuts that collide with ours, the same way
/// CleanShot does. The change lasts only for the login session and is undone on quit;
/// System Settings is left untouched.
enum SystemScreenshotShortcuts {
    /// Symbolic hotkey IDs from com.apple.symbolichotkeys and their default bindings.
    private static let known: [(id: Int32, combo: KeyCombo)] = [
        (28, KeyCombo(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey))),
        (29, KeyCombo(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey | controlKey))),
        (30, KeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey))),
        (31, KeyCombo(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey | controlKey))),
        (184, KeyCombo(keyCode: UInt32(kVK_ANSI_5), modifiers: UInt32(cmdKey | shiftKey))),
        (181, KeyCombo(keyCode: UInt32(kVK_ANSI_6), modifiers: UInt32(cmdKey | shiftKey))),
    ]

    private static var disabled: Set<Int32> = []

    static func yield(to combos: [KeyCombo]) {
        for (id, combo) in known {
            let conflict = combos.contains(combo)
            if conflict, !disabled.contains(id) {
                if CGSSetSymbolicHotKeyEnabled(id, false) == .success { disabled.insert(id) }
            } else if !conflict, disabled.contains(id) {
                _ = CGSSetSymbolicHotKeyEnabled(id, true)
                disabled.remove(id)
            }
        }
    }

    static func restore() {
        for id in disabled { _ = CGSSetSymbolicHotKeyEnabled(id, true) }
        disabled.removeAll()
    }
}

@_silgen_name("CGSSetSymbolicHotKeyEnabled")
private nonisolated func CGSSetSymbolicHotKeyEnabled(_ hotKey: Int32, _ enabled: Bool) -> CGError
