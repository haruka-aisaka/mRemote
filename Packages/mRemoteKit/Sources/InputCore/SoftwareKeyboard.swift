import Foundation
import SessionCore

/// An on-screen modifier.
public enum VirtualModifier: String, Hashable, Sendable, CaseIterable {
    case control
    case alt
    case shift
    case windows

    /// The left-hand usage; the scan code mapper turns it into the key the
    /// host expects.
    public var usage: UInt16 {
        switch self {
        case .control: return 0xE0
        case .shift: return 0xE1
        case .alt: return 0xE2
        case .windows: return 0xE3
        }
    }
}

/// One-shot (the next key only) or locked (every key until turned off).
///
/// Nothing here is ever held down on the host: a modifier is pressed and
/// released around each key it applies to. That costs a few extra events
/// and buys the property that closing the keyboard, switching modes or
/// switching sessions can never leave a virtual Control down on Windows.
public struct VirtualModifierState: Hashable, Sendable {
    public enum Latch: Hashable, Sendable {
        case off
        case oneShot
        case locked
    }

    private var latches: [VirtualModifier: Latch] = [:]

    public init() {}

    public func latch(_ modifier: VirtualModifier) -> Latch {
        latches[modifier, default: .off]
    }

    /// off -> one-shot -> locked -> off.
    public mutating func tap(_ modifier: VirtualModifier) {
        switch latch(modifier) {
        case .off: latches[modifier] = .oneShot
        case .oneShot: latches[modifier] = .locked
        case .locked: latches[modifier] = nil
        }
    }

    public var active: [VirtualModifier] {
        VirtualModifier.allCases.filter { latch($0) != .off }
    }

    public var isEmpty: Bool { active.isEmpty }

    /// After a key: one-shot latches are spent, locked ones stay.
    public mutating func keyWasSent() {
        latches = latches.filter { $0.value == .locked }
    }

    public mutating func releaseAll() {
        latches.removeAll()
    }
}

/// Where a printable ASCII character sits on a Windows keyboard layout.
public struct KeyStroke: Hashable, Sendable {
    public let usage: UInt16
    public let shift: Bool

    public init(usage: UInt16, shift: Bool = false) {
        self.usage = usage
        self.shift = shift
    }
}

/// ASCII to HID usage for the layout the host was told about at connect.
///
/// The usage is a key position, and what a position types depends on the
/// host's layout: on Japanese Windows the key right of `P` types `@`, on US
/// Windows `[`. Host IME mode has to send the position that types the
/// character the user pressed on the software keyboard, so the table follows
/// the session's keyboard profile.
public struct ASCIIKeystrokeMapper: Sendable {
    public let layout: KeyboardLayoutPreference

    public init(layout: KeyboardLayoutPreference) {
        self.layout = layout
    }

    public func keystroke(for character: Character) -> KeyStroke? {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1, scalar.isASCII else {
            // "\r\n" is one Character in Swift; treat it as Enter.
            return character == "\r\n" ? KeyStroke(usage: 0x28) : nil
        }
        let value = scalar.value
        switch value {
        case 0x61...0x7A: return KeyStroke(usage: UInt16(0x04 + value - 0x61))
        case 0x41...0x5A: return KeyStroke(usage: UInt16(0x04 + value - 0x41), shift: true)
        case 0x31...0x39: return KeyStroke(usage: UInt16(0x1E + value - 0x31))
        case 0x30: return KeyStroke(usage: 0x27)
        case 0x0A, 0x0D: return KeyStroke(usage: 0x28)
        case 0x09: return KeyStroke(usage: 0x2B)
        case 0x20: return KeyStroke(usage: 0x2C)
        default: break
        }
        let table = layout == .japanese ? Self.japaneseSymbols : Self.usSymbols
        return table[character]
    }

    /// Windows 106/109.
    private static let japaneseSymbols: [Character: KeyStroke] = [
        "!": KeyStroke(usage: 0x1E, shift: true),
        "\"": KeyStroke(usage: 0x1F, shift: true),
        "#": KeyStroke(usage: 0x20, shift: true),
        "$": KeyStroke(usage: 0x21, shift: true),
        "%": KeyStroke(usage: 0x22, shift: true),
        "&": KeyStroke(usage: 0x23, shift: true),
        "'": KeyStroke(usage: 0x24, shift: true),
        "(": KeyStroke(usage: 0x25, shift: true),
        ")": KeyStroke(usage: 0x26, shift: true),
        "-": KeyStroke(usage: 0x2D),
        "=": KeyStroke(usage: 0x2D, shift: true),
        "^": KeyStroke(usage: 0x2E),
        "~": KeyStroke(usage: 0x2E, shift: true),
        "|": KeyStroke(usage: 0x89, shift: true),
        "@": KeyStroke(usage: 0x2F),
        "`": KeyStroke(usage: 0x2F, shift: true),
        "[": KeyStroke(usage: 0x30),
        "{": KeyStroke(usage: 0x30, shift: true),
        ";": KeyStroke(usage: 0x33),
        "+": KeyStroke(usage: 0x33, shift: true),
        ":": KeyStroke(usage: 0x34),
        "*": KeyStroke(usage: 0x34, shift: true),
        "]": KeyStroke(usage: 0x32),
        "}": KeyStroke(usage: 0x32, shift: true),
        ",": KeyStroke(usage: 0x36),
        "<": KeyStroke(usage: 0x36, shift: true),
        ".": KeyStroke(usage: 0x37),
        ">": KeyStroke(usage: 0x37, shift: true),
        "/": KeyStroke(usage: 0x38),
        "?": KeyStroke(usage: 0x38, shift: true),
        // The ろ key types a backslash on Japanese Windows; ¥ (0x89) would
        // too, but ろ is the one that also gives `_` with Shift.
        "\\": KeyStroke(usage: 0x87),
        "_": KeyStroke(usage: 0x87, shift: true),
    ]

    /// Windows US 101/102.
    private static let usSymbols: [Character: KeyStroke] = [
        "!": KeyStroke(usage: 0x1E, shift: true),
        "@": KeyStroke(usage: 0x1F, shift: true),
        "#": KeyStroke(usage: 0x20, shift: true),
        "$": KeyStroke(usage: 0x21, shift: true),
        "%": KeyStroke(usage: 0x22, shift: true),
        "^": KeyStroke(usage: 0x23, shift: true),
        "&": KeyStroke(usage: 0x24, shift: true),
        "*": KeyStroke(usage: 0x25, shift: true),
        "(": KeyStroke(usage: 0x26, shift: true),
        ")": KeyStroke(usage: 0x27, shift: true),
        "-": KeyStroke(usage: 0x2D),
        "_": KeyStroke(usage: 0x2D, shift: true),
        "=": KeyStroke(usage: 0x2E),
        "+": KeyStroke(usage: 0x2E, shift: true),
        "[": KeyStroke(usage: 0x2F),
        "{": KeyStroke(usage: 0x2F, shift: true),
        "]": KeyStroke(usage: 0x30),
        "}": KeyStroke(usage: 0x30, shift: true),
        "\\": KeyStroke(usage: 0x31),
        "|": KeyStroke(usage: 0x31, shift: true),
        ";": KeyStroke(usage: 0x33),
        ":": KeyStroke(usage: 0x33, shift: true),
        "'": KeyStroke(usage: 0x34),
        "\"": KeyStroke(usage: 0x34, shift: true),
        "`": KeyStroke(usage: 0x35),
        "~": KeyStroke(usage: 0x35, shift: true),
        ",": KeyStroke(usage: 0x36),
        "<": KeyStroke(usage: 0x36, shift: true),
        ".": KeyStroke(usage: 0x37),
        ">": KeyStroke(usage: 0x37, shift: true),
        "/": KeyStroke(usage: 0x38),
        "?": KeyStroke(usage: 0x38, shift: true),
    ]
}

/// What the software keyboard sends, in order.
public enum SoftwareKeyboardOutput: Hashable, Sendable {
    case key(KeyboardInput)
    /// One UTF-16 code unit, typed as a Unicode down/up pair.
    case unicode(UInt16)
}

/// The non-character keys on the extended key bar.
public enum ExtendedKey: String, Hashable, Sendable, CaseIterable {
    case escape, tab, backspace, deleteForward, enter
    case left, right, up, down
    case nonConvert, convert
    case home, end, pageUp, pageDown

    public var usage: UInt16 {
        switch self {
        case .escape: return 0x29
        case .tab: return 0x2B
        case .backspace: return 0x2A
        case .deleteForward: return 0x4C
        case .enter: return 0x28
        case .right: return 0x4F
        case .left: return 0x50
        case .down: return 0x51
        case .up: return 0x52
        case .home: return 0x4A
        case .end: return 0x4D
        case .pageUp: return 0x4B
        case .pageDown: return 0x4E
        // International5/4 rather than LANG2/LANG1: on the host they are the
        // same 無変換/変換 scan codes, and these are what a PC keyboard sends.
        case .nonConvert: return 0x8B
        case .convert: return 0x8A
        }
    }
}

/// Turns software keyboard activity into host input.
///
/// Every chord is complete in itself - modifiers down, key down, key up,
/// modifiers up - so the output never leaves anything held, and there is no
/// remote state for a mode switch or a closed keyboard to unwind.
public struct SoftwareKeyboardComposer: Sendable {
    public var mode: SoftwareKeyboardMode
    public private(set) var modifiers = VirtualModifierState()
    public let mapper: ASCIIKeystrokeMapper

    public init(mode: SoftwareKeyboardMode, layout: KeyboardLayoutPreference) {
        self.mode = mode
        self.mapper = ASCIIKeystrokeMapper(layout: layout)
    }

    public mutating func tapModifier(_ modifier: VirtualModifier) {
        modifiers.tap(modifier)
    }

    public mutating func releaseModifiers() {
        modifiers.releaseAll()
    }

    /// Committed text: everything the system keyboard produced that is no
    /// longer marked. Host IME mode types it as key positions; local IME mode
    /// sends Unicode, except that a character typed under a virtual modifier
    /// becomes a chord, because Ctrl+C means the C key, not the letter.
    public mutating func commit(_ text: String) -> [SoftwareKeyboardOutput] {
        var output: [SoftwareKeyboardOutput] = []
        for character in text {
            let useKey = mode == .hostIME || !modifiers.isEmpty
            if useKey, let stroke = mapper.keystroke(for: character) {
                output += chord(stroke)
            } else if character == "\n" || character == "\r\n" {
                // Enter is a key even in local IME mode: a Unicode CR/LF does
                // not submit a form on Windows.
                output += chord(KeyStroke(usage: ExtendedKey.enter.usage))
            } else {
                output += String(character).utf16.map(SoftwareKeyboardOutput.unicode)
                modifiers.keyWasSent()
            }
        }
        return output
    }

    public mutating func press(_ key: ExtendedKey) -> [SoftwareKeyboardOutput] {
        chord(KeyStroke(usage: key.usage))
    }

    private mutating func chord(_ stroke: KeyStroke) -> [SoftwareKeyboardOutput] {
        var held = modifiers.active.map(\.usage)
        if stroke.shift, !held.contains(VirtualModifier.shift.usage) {
            held.append(VirtualModifier.shift.usage)
        }
        modifiers.keyWasSent()
        let downs = held.map { KeyboardInput(usage: $0, transition: .down) }
        let ups = held.reversed().map { KeyboardInput(usage: $0, transition: .up) }
        return (downs
            + [KeyboardInput(usage: stroke.usage, transition: .down),
               KeyboardInput(usage: stroke.usage, transition: .up)]
            + ups).map(SoftwareKeyboardOutput.key)
    }
}
