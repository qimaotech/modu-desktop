import AppKit
import Carbon

struct GlobalShortcut: Codable, Equatable {
    let keyCode: UInt16
    private let modifiers: UInt

    static let `default` = GlobalShortcut(keyCode: UInt16(kVK_ANSI_Z), modifiers: [.control, .option])
    private static let supportedModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    private static let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
                                       kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
                                       kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.supportedModifiers).rawValue
    }

    var isValid: Bool {
        guard keyCode < 128, keyCode != kVK_Escape, !(54...63).contains(keyCode),
              modifierFlags.intersection(Self.supportedModifiers).rawValue == modifiers else { return false }
        return !modifierFlags.intersection([.command, .control, .option]).isEmpty || Self.functionKeys.contains(Int(keyCode))
    }

    var displayValue: String {
        let symbols: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return symbols.filter { modifierFlags.contains($0.0) }.map(\.1).joined() + keyName
    }

    var carbonModifiers: UInt32 {
        let flags: [(NSEvent.ModifierFlags, Int)] = [(.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)]
        return flags.reduce(0) { $0 | (modifierFlags.contains($1.0) ? UInt32($1.1) : 0) }
    }

    private var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    private var keyName: String {
        if let index = Self.functionKeys.firstIndex(of: Int(keyCode)) { return "F\(index + 1)" }
        let specialKeys = [kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
                           kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
                           kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤"]
        if let name = specialKeys[Int(keyCode)] { return name }
        let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "\(keyCode)" }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        let layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, characters.count, &length, &characters)
        guard status == noErr, length > 0 else { return "\(keyCode)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}
