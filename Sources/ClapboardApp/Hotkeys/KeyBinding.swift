import AppKit
import Carbon.HIToolbox
import Foundation

/// One key combination, stored the way Carbon wants it.
///
/// `RegisterEventHotKey` takes a virtual key code and a Carbon modifier mask,
/// so those are what is persisted: `NSEvent.ModifierFlags` is a Cocoa detail
/// that would have to be converted on every registration anyway, and the key
/// code is layout-independent (⌃⌥M stays on the same physical key when the
/// user switches to Dvorak; only the label changes).
struct KeyBinding: Codable, Hashable, Sendable {
    /// Virtual key code — `kVK_ANSI_M`, `kVK_F13`, …
    var keyCode: UInt32
    /// Carbon modifier mask: `cmdKey | optionKey | controlKey | shiftKey`.
    var carbonModifiers: UInt32

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers & KeyBinding.allCarbonModifiers
    }

    static let allCarbonModifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    // MARK: - Cocoa bridge

    /// The combination a user just typed, or `nil` when it is not usable as a
    /// global hotkey.
    ///
    /// A bare letter is refused: registering `M` globally would swallow the
    /// key everywhere in macOS. Function keys are allowed on their own, which
    /// is what makes F13–F20 on a stream deck the natural mute key.
    init?(event: NSEvent) {
        let carbon = KeyBinding.carbonModifiers(from: event.modifierFlags)
        let code = UInt32(event.keyCode)
        let hasRealModifier = carbon & UInt32(cmdKey | optionKey | controlKey) != 0
        guard hasRealModifier || KeyBinding.functionKeyCodes.contains(code) else { return nil }
        self.init(keyCode: code, carbonModifiers: carbon)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbonModifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    // MARK: - Display

    /// `⌃⌥M`, `F13`, `⇧⌘Space`. Menu order — control, option, shift, command.
    var displayString: String {
        KeyBinding.modifierSymbols(carbonModifiers) + KeyBinding.keyName(keyCode)
    }

    static func modifierSymbols(_ carbon: UInt32) -> String {
        var text = ""
        if carbon & UInt32(controlKey) != 0 { text += "⌃" }
        if carbon & UInt32(optionKey) != 0 { text += "⌥" }
        if carbon & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbon & UInt32(cmdKey) != 0 { text += "⌘" }
        return text
    }

    /// The label for one key. Named keys come from the table; everything else
    /// is asked of the *current* keyboard layout, so a French layout shows the
    /// letter the user's fingers actually produce.
    static func keyName(_ keyCode: UInt32) -> String {
        if let named = namedKeys[keyCode] { return named }
        if let translated = layoutName(keyCode) { return translated }
        return "Key \(keyCode)"
    }

    private static func layoutName(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data

        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,                       // no modifiers: the unshifted label
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length)
        return text.isEmpty ? nil : text.uppercased()
    }

    /// Keys whose label is not the character they type.
    private static let namedKeys: [UInt32: String] = [
        UInt32(kVK_Return): "↩",
        UInt32(kVK_Tab): "⇥",
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Delete): "⌫",
        UInt32(kVK_ForwardDelete): "⌦",
        UInt32(kVK_Escape): "⎋",
        UInt32(kVK_Help): "Help",
        UInt32(kVK_Home): "↖",
        UInt32(kVK_End): "↘",
        UInt32(kVK_PageUp): "⇞",
        UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_ANSI_KeypadEnter): "⌤",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15",
        UInt32(kVK_F16): "F16", UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18",
        UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20"
    ]

    /// The keys that may stand alone, without a modifier.
    static let functionKeyCodes: Set<UInt32> = [
        UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4),
        UInt32(kVK_F5), UInt32(kVK_F6), UInt32(kVK_F7), UInt32(kVK_F8),
        UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
        UInt32(kVK_F13), UInt32(kVK_F14), UInt32(kVK_F15), UInt32(kVK_F16),
        UInt32(kVK_F17), UInt32(kVK_F18), UInt32(kVK_F19), UInt32(kVK_F20)
    ]

    // MARK: - Safety

    /// Combinations that must not become global hotkeys, with the reason.
    ///
    /// This matters more here than in an ordinary shortcut recorder: a Carbon
    /// hotkey *swallows* the key everywhere, so binding ⌘Q to the mute key
    /// would take Quit away from every app on the machine — and the way to
    /// undo it would be to quit Clapboard.
    var systemReservedReason: String? {
        let command = carbonModifiers & UInt32(cmdKey) != 0
        let option = carbonModifiers & UInt32(optionKey) != 0
        let onlyCommandish = carbonModifiers & ~UInt32(cmdKey | shiftKey) == 0
        guard command else { return nil }
        switch Int(keyCode) {
        case kVK_ANSI_Q where onlyCommandish: return "⌘Q quits apps"
        case kVK_ANSI_W where onlyCommandish: return "⌘W closes windows"
        case kVK_Tab where onlyCommandish: return "⌘⇥ switches apps"
        case kVK_Space where onlyCommandish: return "⌘Space opens Spotlight"
        case kVK_Escape where option: return "⌥⌘⎋ is Force Quit"
        default: return nil
        }
    }

    // MARK: - Defaults

    /// `⌃⌥M` — free on a stock macOS, and reachable with one hand.
    static let defaultToggleAll = KeyBinding(
        keyCode: UInt32(kVK_ANSI_M),
        carbonModifiers: UInt32(controlKey | optionKey)
    )
}
