import Foundation

/// A Set 1 scan code ready for the typed FreeRDP adapter boundary.
struct RDPSet1ScanCode: Equatable, Sendable, CustomStringConvertible {
    let value: UInt8
    let isExtended: Bool

    var description: String {
        String(format: "%@0x%02X", isExtended ? "E0 " : "", value)
    }
}

enum RDPScanCodeMappingError: Error, Equatable, CustomStringConvertible {
    case unsupportedHIDUsage(UInt16)

    var description: String {
        switch self {
        case let .unsupportedHIDUsage(usage):
            return String(format: "unsupported HID usage 0x%02X", usage)
        }
    }
}

enum RDPScanCodeMapper {
    /// HID usage page 0x07 to PC/AT Set 1, with the RDP extended selector kept
    /// out of the code byte because `mr_rdp_key_event` carries it as its own
    /// flag. A usage outside this table is rejected rather than guessed.
    static func set1ScanCode(forHIDUsage usage: UInt16) throws -> RDPSet1ScanCode {
        guard let scanCode = table[usage] else {
            throw RDPScanCodeMappingError.unsupportedHIDUsage(usage)
        }
        return scanCode
    }

    private static func code(_ value: UInt8) -> RDPSet1ScanCode {
        RDPSet1ScanCode(value: value, isExtended: false)
    }

    private static func extended(_ value: UInt8) -> RDPSet1ScanCode {
        RDPSet1ScanCode(value: value, isExtended: true)
    }

    private static let table: [UInt16: RDPSet1ScanCode] = {
        var table: [UInt16: RDPSet1ScanCode] = [:]

        // A-Z, in HID usage order rather than alphabetical scan code order.
        let letters: [UInt8] = [
            0x1E, 0x30, 0x2E, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17,
            0x24, 0x25, 0x26, 0x32, 0x31, 0x18, 0x19, 0x10, 0x13,
            0x1F, 0x14, 0x16, 0x2F, 0x11, 0x2D, 0x15, 0x2C,
        ]
        for (offset, value) in letters.enumerated() {
            table[UInt16(0x04 + offset)] = code(value)
        }

        // 1-9 then 0, matching the top row's HID order.
        for (offset, value) in [UInt8](0x02...0x0B).enumerated() {
            table[UInt16(0x1E + offset)] = code(value)
        }

        table[0x28] = code(0x1C) // Return
        table[0x29] = code(0x01) // Escape
        table[0x2A] = code(0x0E) // Backspace
        table[0x2B] = code(0x0F) // Tab
        table[0x2C] = code(0x39) // Space
        table[0x2D] = code(0x0C) // - _
        table[0x2E] = code(0x0D) // = +
        table[0x2F] = code(0x1A) // [ {
        table[0x30] = code(0x1B) // ] }
        table[0x31] = code(0x2B) // \ |
        table[0x32] = code(0x2B) // Non-US # ~, same position as backslash
        table[0x33] = code(0x27) // ; :
        table[0x34] = code(0x28) // ' "
        table[0x35] = code(0x29) // ` ~
        table[0x36] = code(0x33) // , <
        table[0x37] = code(0x34) // . >
        table[0x38] = code(0x35) // / ?
        table[0x39] = code(0x3A) // Caps Lock

        // F1-F10 are contiguous; F11/F12 are not.
        for (offset, value) in [UInt8](0x3B...0x44).enumerated() {
            table[UInt16(0x3A + offset)] = code(value)
        }
        table[0x44] = code(0x57) // F11
        table[0x45] = code(0x58) // F12

        table[0x46] = extended(0x37) // Print Screen
        table[0x47] = code(0x46) // Scroll Lock
        // 0x48 Pause is intentionally absent: it is an EXTENDED1 sequence of
        // two scan codes, which this single-code event cannot express.
        table[0x49] = extended(0x52) // Insert
        table[0x4A] = extended(0x47) // Home
        table[0x4B] = extended(0x49) // Page Up
        table[0x4C] = extended(0x53) // Delete
        table[0x4D] = extended(0x4F) // End
        table[0x4E] = extended(0x51) // Page Down
        table[0x4F] = extended(0x4D) // Right Arrow
        table[0x50] = extended(0x4B) // Left Arrow
        table[0x51] = extended(0x50) // Down Arrow
        table[0x52] = extended(0x48) // Up Arrow

        table[0x53] = code(0x45) // Num Lock
        table[0x54] = extended(0x35) // Keypad /
        table[0x55] = code(0x37) // Keypad *
        table[0x56] = code(0x4A) // Keypad -
        table[0x57] = code(0x4E) // Keypad +
        table[0x58] = extended(0x1C) // Keypad Enter
        // Keypad 1-9, 0, then the decimal separator.
        let keypadDigits: [UInt8] = [
            0x4F, 0x50, 0x51, 0x4B, 0x4C, 0x4D, 0x47, 0x48, 0x49, 0x52, 0x53,
        ]
        for (offset, value) in keypadDigits.enumerated() {
            table[UInt16(0x59 + offset)] = code(value)
        }

        table[0x64] = code(0x56) // Non-US \ |
        table[0x65] = extended(0x5D) // Application
        table[0x67] = code(0x59) // Keypad =

        // F13-F23 are contiguous; F24 is not.
        for (offset, value) in [UInt8](0x64...0x6E).enumerated() {
            table[UInt16(0x68 + offset)] = code(value)
        }
        table[0x73] = code(0x76) // F24

        table[0x85] = code(0x7E) // Keypad comma (JIS keypad)

        // Japanese keys. These follow docs/input-design.md section 6: the
        // 英数/かな rows are this app's required meaning conversion, and the
        // PC JIS rows are the candidate mapping recorded there.
        table[0x87] = code(0x73) // Intl1, JIS ろ
        table[0x88] = code(0x70) // Intl2, カナ / VK_KANA
        table[0x89] = code(0x7D) // Intl3, JIS ¥
        table[0x8A] = code(0x79) // Intl4, 変換 / VK_CONVERT
        table[0x8B] = code(0x7B) // Intl5, 無変換 / VK_NONCONVERT
        table[HIDUsage.kana] = code(0x79) // LANG1 → 変換 / VK_CONVERT
        table[HIDUsage.eisu] = code(0x7B) // LANG2 → 無変換 / VK_NONCONVERT
        table[0x94] = code(0x29) // LANG5, 半角/全角

        table[0xE0] = code(0x1D) // Left Control
        table[0xE1] = code(0x2A) // Left Shift
        table[0xE2] = code(0x38) // Left Alt
        table[0xE3] = extended(0x5B) // Left GUI
        table[0xE4] = extended(0x1D) // Right Control
        table[0xE5] = code(0x36) // Right Shift
        table[0xE6] = extended(0x38) // Right Alt
        table[0xE7] = extended(0x5C) // Right GUI

        return table
    }()
}
