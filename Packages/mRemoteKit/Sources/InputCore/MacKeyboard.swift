import Foundation

/// The Mac's physical keyboard, as AppKit reports it, in the HID usages the
/// rest of the input path speaks.
///
/// On Mac Catalyst UIKit hands the app neither 英数/かな nor any key that a
/// menu item claims (⌘W, ⌘C, ⌘N...): the first are dispatched to no window
/// at all, the second become menu actions. So on the Mac the session takes key
/// events from AppKit instead, where every key arrives as a virtual key code,
/// and this table turns that code into the usage `pressesBegan` would have
/// carried on an iPad. Codes are the `kVK_*` constants of
/// HIToolbox/Events.h, which describe key positions, not characters.
public enum MacVirtualKey {
    /// The usage for a virtual key code, or nil for keys the host has no
    /// equivalent for (Fn, the media keys).
    public static func usage(for keyCode: UInt16) -> UInt16? {
        table[keyCode]
    }

    /// The modifier a `flagsChanged` key code stands for, and the bit in
    /// `NSEvent.modifierFlags` that says whether that very key - left or
    /// right - is now down.
    public static func modifier(for keyCode: UInt16) -> (usage: UInt16, deviceFlag: UInt64)? {
        switch keyCode {
        case 59: return (0xE0, 0x0000_0001) // left Control,  NX_DEVICELCTLKEYMASK
        case 56: return (0xE1, 0x0000_0002) // left Shift,    NX_DEVICELSHIFTKEYMASK
        case 58: return (0xE2, 0x0000_0020) // left Option,   NX_DEVICELALTKEYMASK
        case 55: return (0xE3, 0x0000_0008) // left Command,  NX_DEVICELCMDKEYMASK
        case 62: return (0xE4, 0x0000_2000) // right Control, NX_DEVICERCTLKEYMASK
        case 60: return (0xE5, 0x0000_0004) // right Shift,   NX_DEVICERSHIFTKEYMASK
        case 61: return (0xE6, 0x0000_0040) // right Option,  NX_DEVICERALTKEYMASK
        case 54: return (0xE7, 0x0000_0010) // right Command, NX_DEVICERCMDKEYMASK
        default: return nil
        }
    }

    /// Whether the modifier a `flagsChanged` named is now down. A keyboard
    /// sets the left/right device bit; an event without any device bit - one
    /// posted by software - only carries the device-independent flag, which
    /// is then the answer.
    public static func isModifierDown(_ modifier: (usage: UInt16, deviceFlag: UInt64), flags: UInt64) -> Bool {
        if flags & allDeviceFlags != 0 {
            return flags & modifier.deviceFlag != 0
        }
        let independent: UInt64
        switch modifier.usage {
        case 0xE0, 0xE4: independent = 1 << 18 // NSEvent.ModifierFlags.control
        case 0xE1, 0xE5: independent = 1 << 17 // .shift
        case 0xE2, 0xE6: independent = 1 << 19 // .option
        default: independent = 1 << 20         // .command
        }
        return flags & independent != 0
    }

    private static let allDeviceFlags: UInt64 = 0x0000_207F

    /// Caps Lock reports a state, not a press: one `flagsChanged` each time
    /// it locks or unlocks. Each is sent to the host as a full press so the
    /// host's own lock follows.
    public static let capsLock: UInt16 = 57

    /// Shortcuts that keep working on the Mac while the session has the
    /// keyboard, so the window can still be quit, hidden, minimised, cycled
    /// and taken full screen. Everything else - ⌘W and ⌘C included - goes to
    /// the host, where Command is the Windows key.
    public static func isReservedForMac(keyCode: UInt16, command: Bool, control: Bool) -> Bool {
        guard command else { return false }
        switch keyCode {
        case 12, 4, 46, 50: return true // Q, H, M, ` (cycle windows)
        case 3: return control          // ⌃⌘F, full screen
        default: return false
        }
    }

    private static let table: [UInt16: UInt16] = [
        // Letters, by position.
        0: 0x04, 11: 0x05, 8: 0x06, 2: 0x07, 14: 0x08, 3: 0x09, 5: 0x0A, 4: 0x0B,
        34: 0x0C, 38: 0x0D, 40: 0x0E, 37: 0x0F, 46: 0x10, 45: 0x11, 31: 0x12, 35: 0x13,
        12: 0x14, 15: 0x15, 1: 0x16, 17: 0x17, 32: 0x18, 9: 0x19, 13: 0x1A, 7: 0x1B,
        16: 0x1C, 6: 0x1D,
        // Digits 1-9, 0.
        18: 0x1E, 19: 0x1F, 20: 0x20, 21: 0x21, 23: 0x22, 22: 0x23, 26: 0x24, 28: 0x25,
        25: 0x26, 29: 0x27,
        // Return, Escape, Delete (backspace), Tab, Space.
        36: 0x28, 53: 0x29, 51: 0x2A, 48: 0x2B, 49: 0x2C,
        // - = [ ] \ ; ' ` , . /
        27: 0x2D, 24: 0x2E, 33: 0x2F, 30: 0x30, 42: 0x31, 41: 0x33, 39: 0x34, 50: 0x35,
        43: 0x36, 47: 0x37, 44: 0x38,
        // ISO §, the key left of 1 / right of left Shift on ISO boards.
        10: 0x64,
        // F1-F12.
        122: 0x3A, 120: 0x3B, 99: 0x3C, 118: 0x3D, 96: 0x3E, 97: 0x3F, 98: 0x40, 100: 0x41,
        101: 0x42, 109: 0x43, 103: 0x44, 111: 0x45,
        // F13-F20.
        105: 0x68, 107: 0x69, 113: 0x6A, 106: 0x6B, 64: 0x6C, 79: 0x6D, 80: 0x6E, 90: 0x6F,
        // Help (Insert on PC keyboards), Home, Page Up, Forward Delete, End,
        // Page Down, the PC keyboard's application (menu) key.
        114: 0x49, 115: 0x4A, 116: 0x4B, 117: 0x4C, 119: 0x4D, 121: 0x4E, 110: 0x65,
        // Arrows: right, left, down, up.
        124: 0x4F, 123: 0x50, 125: 0x51, 126: 0x52,
        // Keypad: Clear (Num Lock), / * - + Enter, 1-9, 0, ., =.
        71: 0x53, 75: 0x54, 67: 0x55, 78: 0x56, 69: 0x57, 76: 0x58,
        83: 0x59, 84: 0x5A, 85: 0x5B, 86: 0x5C, 87: 0x5D, 88: 0x5E, 89: 0x5F, 91: 0x60,
        92: 0x61, 82: 0x62, 65: 0x63, 81: 0x67,
        // JIS: ろ (Intl1), ¥ (Intl3), keypad comma, かな (LANG1), 英数 (LANG2).
        94: 0x87, 93: 0x89, 95: 0x85, 104: 0x90, 102: 0x91,
    ]
}
