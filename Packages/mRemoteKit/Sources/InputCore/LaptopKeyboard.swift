import Foundation
import SessionCore

/// One key on the on-screen laptop keyboard shown in a foldable's laptop
/// posture.
///
/// Unlike the software keyboard, which types characters, this one is a
/// picture of a PC keyboard: each key is a key position, sent as its HID
/// usage, so what it types is whatever the host's layout and IME make of it -
/// exactly as with a physical keyboard plugged into the host.
public struct LaptopKey: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// A key that goes down while touched and up when released.
        case key(UInt16)
        /// Ctrl, Alt, Shift, Win: held while touched, latched when tapped.
        case modifier(VirtualModifier)
        /// Drawn but sends nothing: a Mac Caps Lock set to No Action.
        case inert
    }

    /// Unique within a row, so a left and a right Shift are two keys. The
    /// same identifier in two adjacent rows is one key drawn across both -
    /// the JIS Enter, whose cap is an inverted L.
    public let id: String
    public let label: String
    /// What Shift produces, drawn small above the label. Nil when it is the
    /// same key (letters) or meaningless (Enter).
    public let shiftedLabel: String?
    public let kind: Kind
    /// In key units; every row of a layout adds up to the same total.
    public let width: Double
    /// A modifier that does something on its own: the Windows key, which
    /// opens Start when pressed and released with nothing in between. A
    /// quick tap sends it; holding it still latches it instead.
    public let sendsWhenTappedAlone: Bool

    public init(
        id: String,
        label: String,
        shiftedLabel: String? = nil,
        kind: Kind,
        width: Double = 1,
        sendsWhenTappedAlone: Bool = false
    ) {
        self.id = id
        self.label = label
        self.shiftedLabel = shiftedLabel
        self.kind = kind
        self.width = width
        self.sendsWhenTappedAlone = sendsWhenTappedAlone
    }

    public var isModifier: Bool {
        if case .modifier = kind { return true }
        return false
    }

    /// Arrows, Backspace and the like repeat while held; modifiers and the
    /// IME keys do not, because repeating 半/全 would flip the IME on and off.
    public var repeats: Bool {
        guard case .key(let usage) = kind else { return false }
        return !Self.nonRepeatingUsages.contains(usage)
    }

    private static let nonRepeatingUsages: Set<UInt16> = [
        0x29, // Escape
        0x35, // 半角/全角 on JIS, ` on US - the JIS meaning wins
        0x39, // Caps Lock / 英数
        0x88, // かな
        0x8A, // 変換
        0x8B, // 無変換
        0x90, // LANG1, Mac かな
        0x91, // LANG2, Mac 英数
    ]
}

public struct LaptopKeyboardRow: Hashable, Sendable {
    public let keys: [LaptopKey]
    /// Relative to an ordinary row; the function row is shorter.
    public let height: Double

    public init(_ keys: [LaptopKey], height: Double = 1) {
        self.keys = keys
        self.height = height
    }

    public var totalWidth: Double { keys.reduce(0) { $0 + $1.width } }
}

/// Whose keyboard the deck draws: a PC's, or a Mac's.
///
/// The same positions are sent either way - Command is the GUI key that
/// Windows calls Win, Option is Alt - so this changes the picture and the
/// handful of keys that differ, such as 英数/かな in place of 無変換/変換.
public enum LaptopKeyboardPlatform: String, Hashable, Sendable, CaseIterable {
    case windows
    /// Modelled on Apple's Magic Keyboard without a numeric keypad. There is
    /// no fn key: it is not a usage a host can receive.
    case mac
}

/// What the Caps Lock key does.
///
/// macOS lets the user give it another modifier's job, or none, in Keyboard
/// > Modifier Keys, and on Windows it is commonly remapped to Control; the
/// deck offers the same so it behaves like the keyboard the user is used to.
public enum CapsLockRole: String, Hashable, Sendable, CaseIterable {
    case capsLock
    case control
    case option
    case command
    case escape
    case noAction

    /// The roles worth offering on a Windows host; the rest are Mac habits.
    public static let windowsRoles: [CapsLockRole] = [.capsLock, .control]

    /// The roles offered for a deck drawn as `platform`'s keyboard: on a
    /// Mac's, every choice macOS's Modifier Keys has.
    public static func roles(on platform: LaptopKeyboardPlatform) -> [CapsLockRole] {
        platform == .mac ? allCases : windowsRoles
    }

    fileprivate func key(width: Double, platform: LaptopKeyboardPlatform) -> LaptopKey {
        let id = "capslock"
        let mac = platform == .mac
        switch self {
        case .capsLock:
            let label = mac ? (width > 1.5 ? "caps lock" : "caps") : "Caps"
            return LaptopKey(id: id, label: label, kind: .key(0x39), width: width)
        case .control:
            return LaptopKey(id: id, label: mac ? "control" : "Ctrl", kind: .modifier(.control), width: width)
        case .option:
            return LaptopKey(id: id, label: mac ? "⌥" : "Alt", kind: .modifier(.alt), width: width)
        case .command:
            return LaptopKey(id: id, label: mac ? "⌘" : "Win", kind: .modifier(.windows), width: width)
        case .escape:
            return LaptopKey(id: id, label: mac ? "esc" : "Esc", kind: .key(0x29), width: width)
        case .noAction:
            return LaptopKey(id: id, label: mac ? "caps" : "Caps", kind: .inert, width: width)
        }
    }
}

/// The rows of the laptop keyboard for the host's layout.
///
/// The layout follows the session's keyboard profile rather than the
/// device's, for the same reason `ASCIIKeystrokeMapper` does: a usage is a
/// position, and the label has to say what that position types on the host.
public struct LaptopKeyboardLayout: Hashable, Sendable {
    public static let unitsPerRow = 15.0

    public let rows: [LaptopKeyboardRow]

    /// - Parameter capsLockRole: what the Caps Lock key does.
    public init(
        _ layout: KeyboardLayoutPreference,
        platform: LaptopKeyboardPlatform = .windows,
        capsLockRole: CapsLockRole = .capsLock
    ) {
        // Automatic draws US, as `ASCIIKeystrokeMapper` assumes it.
        let isJapanese = layout == .japanese
        let base: [LaptopKeyboardRow]
        switch platform {
        case .windows:
            base = [Self.functionRow] + (isJapanese ? Self.japaneseRows : Self.usRows)
        case .mac:
            base = [Self.macFunctionRow] + (isJapanese ? Self.macJapaneseRows : Self.macUSRows)
        }
        rows = base.map { row in
            LaptopKeyboardRow(
                row.keys.map {
                    $0.id == "capslock" ? capsLockRole.key(width: $0.width, platform: platform) : $0
                },
                height: row.height
            )
        }
    }

    /// Every key once, in reading order; a key spanning two rows is listed
    /// where it starts.
    public var keys: [LaptopKey] {
        var seen: Set<String> = []
        return rows.flatMap(\.keys).filter { seen.insert($0.id).inserted }
    }

    // MARK: - Shared rows

    private static let functionRow = LaptopKeyboardRow(
        [key("esc", "Esc", 0x29, width: 1.5)]
            + (1...12).map { number in
                key("f\(number)", "F\(number)", UInt16(0x3A + number - 1))
            }
            + [key("delete", "Del", 0x4C, width: 1.5)],
        height: 0.7
    )

    private static let macFunctionRow = LaptopKeyboardRow(
        [key("esc", "esc", 0x29, width: 1.5)]
            + (1...12).map { number in
                key("f\(number)", "F\(number)", UInt16(0x3A + number - 1))
            }
            // A Mac reaches forward delete with fn, which is not on offer.
            + [key("delete", "⌦", 0x4C, width: 1.5)],
        height: 0.7
    )

    private static func letters(_ string: String) -> [LaptopKey] {
        string.map { character in
            let scalar = character.unicodeScalars.first!.value
            return key(
                String(character).lowercased(),
                String(character),
                UInt16(0x04 + scalar - 0x41)
            )
        }
    }

    private static func digits() -> [LaptopKey] {
        (1...10).map { index in
            let digit = index % 10
            return key("digit\(digit)", "\(digit)", UInt16(0x1E + index - 1))
        }
    }

    private static func key(
        _ id: String,
        _ label: String,
        _ usage: UInt16,
        shifted: String? = nil,
        width: Double = 1
    ) -> LaptopKey {
        LaptopKey(id: id, label: label, shiftedLabel: shifted, kind: .key(usage), width: width)
    }

    private static func modifier(
        _ id: String,
        _ label: String,
        _ modifier: VirtualModifier,
        width: Double,
        sendsWhenTappedAlone: Bool = false
    ) -> LaptopKey {
        LaptopKey(
            id: id,
            label: label,
            kind: .modifier(modifier),
            width: width,
            sendsWhenTappedAlone: sendsWhenTappedAlone
        )
    }

    private static func withShifted(_ keys: [LaptopKey], _ shifted: [String?]) -> [LaptopKey] {
        zip(keys, shifted).map { key, shifted in
            LaptopKey(
                id: key.id,
                label: key.label,
                shiftedLabel: shifted,
                kind: key.kind,
                width: key.width
            )
        }
    }

    private static let arrowsLeftDownRight = [
        key("left", "←", 0x50),
        key("down", "↓", 0x51),
        key("right", "→", 0x4F),
    ]

    // MARK: - Windows 106/109

    private static let japaneseRows: [LaptopKeyboardRow] = [
        LaptopKeyboardRow(
            [key("zenkaku", "半/全", 0x35)]
                + withShifted(digits(), ["!", "\"", "#", "$", "%", "&", "'", "(", ")", nil])
                + [
                    key("minus", "-", 0x2D, shifted: "="),
                    key("caret", "^", 0x2E, shifted: "~"),
                    key("yen", "¥", 0x89, shifted: "|"),
                    key("backspace", "⌫", 0x2A),
                ]
        ),
        LaptopKeyboardRow(
            [key("tab", "Tab", 0x2B, width: 1.5)]
                + letters("QWERTYUIOP")
                + [
                    key("at", "@", 0x2F, shifted: "`"),
                    key("bracketleft", "[", 0x30, shifted: "{"),
                    key("enter", "⏎", 0x28, width: 1.5),
                ]
        ),
        LaptopKeyboardRow(
            // 英数 is printed on this key too, and unshifted it does toggle
            // the Japanese IME; what it is, though, is Caps Lock.
            [key("capslock", "Caps", 0x39, width: 1.75)]
                + letters("ASDFGHJKL")
                + [
                    key("semicolon", ";", 0x33, shifted: "+"),
                    key("colon", ":", 0x34, shifted: "*"),
                    key("bracketright", "]", 0x32, shifted: "}"),
                    // The lower, narrower part of the same Enter.
                    key("enter", "⏎", 0x28, width: 1.25),
                ]
        ),
        LaptopKeyboardRow(
            [modifier("shift-left", "Shift", .shift, width: 2)]
                + letters("ZXCVBNM")
                + [
                    key("comma", ",", 0x36, shifted: "<"),
                    key("period", ".", 0x37, shifted: ">"),
                    key("slash", "/", 0x38, shifted: "?"),
                    key("ro", "\\", 0x87, shifted: "_"),
                    // ↑ over ↓ rather than over →: the arrows make an
                    // inverted T, as on most laptops.
                    key("up", "↑", 0x52),
                    modifier("shift-right", "Shift", .shift, width: 1),
                ]
        ),
        LaptopKeyboardRow(
            [
                modifier("control-left", "Ctrl", .control, width: 1.25),
                modifier("windows", "Win", .windows, width: 1, sendsWhenTappedAlone: true),
                modifier("alt-left", "Alt", .alt, width: 1),
                key("nonconvert", "無変換", 0x8B, width: 1.25),
                key("space", "", 0x2C, width: 4),
                key("convert", "変換", 0x8A, width: 1.25),
                key("kana", "かな", 0x88, width: 1.25),
                modifier("alt-right", "Alt", .alt, width: 1),
            ] + arrowsLeftDownRight
        ),
    ]

    // MARK: - Windows US 101/102

    private static let usRows: [LaptopKeyboardRow] = [
        LaptopKeyboardRow(
            [key("grave", "`", 0x35, shifted: "~")]
                + withShifted(digits(), ["!", "@", "#", "$", "%", "^", "&", "*", "(", ")"])
                + [
                    key("minus", "-", 0x2D, shifted: "_"),
                    key("equal", "=", 0x2E, shifted: "+"),
                    key("backspace", "⌫", 0x2A, width: 2),
                ]
        ),
        LaptopKeyboardRow(
            [key("tab", "Tab", 0x2B, width: 1.5)]
                + letters("QWERTYUIOP")
                + [
                    key("bracketleft", "[", 0x2F, shifted: "{"),
                    key("bracketright", "]", 0x30, shifted: "}"),
                    key("backslash", "\\", 0x31, shifted: "|", width: 1.5),
                ]
        ),
        LaptopKeyboardRow(
            [key("capslock", "Caps", 0x39, width: 1.75)]
                + letters("ASDFGHJKL")
                + [
                    key("semicolon", ";", 0x33, shifted: ":"),
                    key("quote", "'", 0x34, shifted: "\""),
                    key("enter", "⏎", 0x28, width: 2.25),
                ]
        ),
        LaptopKeyboardRow(
            [modifier("shift-left", "Shift", .shift, width: 2.25)]
                + letters("ZXCVBNM")
                + [
                    key("comma", ",", 0x36, shifted: "<"),
                    key("period", ".", 0x37, shifted: ">"),
                    key("slash", "/", 0x38, shifted: "?"),
                    modifier("shift-right", "Shift", .shift, width: 1.75),
                    key("up", "↑", 0x52),
                ]
        ),
        LaptopKeyboardRow(
            [
                modifier("control-left", "Ctrl", .control, width: 1.25),
                modifier("windows", "Win", .windows, width: 1.25, sendsWhenTappedAlone: true),
                modifier("alt-left", "Alt", .alt, width: 1.25),
                key("space", "", 0x2C, width: 5.75),
                modifier("alt-right", "Alt", .alt, width: 1.25),
                modifier("control-right", "Ctrl", .control, width: 1.25),
            ] + arrowsLeftDownRight
        ),
    ]
    // MARK: - Mac (Magic Keyboard) JIS

    private static let macJapaneseRows: [LaptopKeyboardRow] = [
        LaptopKeyboardRow(
            withShifted(digits(), ["!", "\"", "#", "$", "%", "&", "'", "(", ")", nil])
                + [
                    key("minus", "-", 0x2D, shifted: "="),
                    key("caret", "^", 0x2E, shifted: "~"),
                    key("yen", "¥", 0x89, shifted: "|"),
                    key("backspace", "delete", 0x2A, width: 2),
                ]
        ),
        LaptopKeyboardRow(
            [key("tab", "tab", 0x2B, width: 1.5)]
                + letters("QWERTYUIOP")
                + [
                    key("at", "@", 0x2F, shifted: "`"),
                    key("bracketleft", "[", 0x30, shifted: "{"),
                    key("enter", "return", 0x28, width: 1.5),
                ]
        ),
        LaptopKeyboardRow(
            // Control sits where Caps Lock does on a PC, as on every Mac JIS.
            [modifier("control-left", "control", .control, width: 1.75)]
                + letters("ASDFGHJKL")
                + [
                    key("semicolon", ";", 0x33, shifted: "+"),
                    key("colon", ":", 0x34, shifted: "*"),
                    key("bracketright", "]", 0x32, shifted: "}"),
                    key("enter", "return", 0x28, width: 1.25),
                ]
        ),
        LaptopKeyboardRow(
            [modifier("shift-left", "shift", .shift, width: 2)]
                + letters("ZXCVBNM")
                + [
                    key("comma", ",", 0x36, shifted: "<"),
                    key("period", ".", 0x37, shifted: ">"),
                    key("slash", "/", 0x38, shifted: "?"),
                    key("ro", "_", 0x87, shifted: "ろ"),
                    key("up", "↑", 0x52),
                    modifier("shift-right", "shift", .shift, width: 1),
                ]
        ),
        LaptopKeyboardRow(
            [
                key("capslock", "caps", 0x39, width: 1),
                modifier("alt-left", "⌥", .alt, width: 1),
                modifier("command-left", "⌘", .windows, width: 1.25),
                // LANG2 and LANG1: what a Mac's JIS keyboard sends, and what
                // RDP turns into 無変換 and 変換.
                key("eisu", "英数", 0x91, width: 1.25),
                key("space", "", 0x2C, width: 5),
                key("kana", "かな", 0x90, width: 1.25),
                modifier("command-right", "⌘", .windows, width: 1.25),
            ] + arrowsLeftDownRight
        ),
    ]

    // MARK: - Mac (Magic Keyboard) US

    private static let macUSRows: [LaptopKeyboardRow] = [
        LaptopKeyboardRow(
            [key("grave", "`", 0x35, shifted: "~")]
                + withShifted(digits(), ["!", "@", "#", "$", "%", "^", "&", "*", "(", ")"])
                + [
                    key("minus", "-", 0x2D, shifted: "_"),
                    key("equal", "=", 0x2E, shifted: "+"),
                    key("backspace", "delete", 0x2A, width: 2),
                ]
        ),
        LaptopKeyboardRow(
            [key("tab", "tab", 0x2B, width: 1.5)]
                + letters("QWERTYUIOP")
                + [
                    key("bracketleft", "[", 0x2F, shifted: "{"),
                    key("bracketright", "]", 0x30, shifted: "}"),
                    key("backslash", "\\", 0x31, shifted: "|", width: 1.5),
                ]
        ),
        LaptopKeyboardRow(
            [key("capslock", "caps lock", 0x39, width: 1.75)]
                + letters("ASDFGHJKL")
                + [
                    key("semicolon", ";", 0x33, shifted: ":"),
                    key("quote", "'", 0x34, shifted: "\""),
                    key("enter", "return", 0x28, width: 2.25),
                ]
        ),
        LaptopKeyboardRow(
            // Narrower right Shift than a real Magic Keyboard, so that up sits
            // over down and the arrows make an inverted T.
            [modifier("shift-left", "shift", .shift, width: 3)]
                + letters("ZXCVBNM")
                + [
                    key("comma", ",", 0x36, shifted: "<"),
                    key("period", ".", 0x37, shifted: ">"),
                    key("slash", "/", 0x38, shifted: "?"),
                    key("up", "↑", 0x52),
                    modifier("shift-right", "shift", .shift, width: 1),
                ]
        ),
        LaptopKeyboardRow(
            [
                modifier("control-left", "control", .control, width: 1.25),
                modifier("alt-left", "⌥", .alt, width: 1.25),
                modifier("command-left", "⌘", .windows, width: 1.5),
                key("space", "", 0x2C, width: 5),
                modifier("command-right", "⌘", .windows, width: 1.5),
                modifier("alt-right", "⌥", .alt, width: 1.5),
            ] + arrowsLeftDownRight
        ),
    ]
}

/// Turns touches on the laptop keyboard into host key transitions.
///
/// A key is down on the host exactly as long as a finger is on it, which is
/// what gives Backspace and the arrows their repeat and lets a game see a
/// held key. Modifiers work two ways at once, because both are how people
/// use a touch keyboard:
///
/// - held: a finger on Shift while another taps A is Shift+A, as on a real
///   keyboard;
/// - tapped: a modifier touched and released with no key in between latches
///   (one-shot, then locked, then off), so Ctrl+Alt+Del can be typed with
///   one finger.
///
/// The Windows key is the exception, because on its own it opens Start: a
/// quick tap sends it, and it latches only when held past
/// `latchHoldDuration` - or tapped again while already latched.
///
/// A modifier is pressed on the host only around the keys it applies to and
/// is reference-counted across overlapping keys, so releasing everything is
/// always one well-defined list of ups.
public struct LaptopKeyboardComposer: Sendable {
    public private(set) var latches = VirtualModifierState()
    /// Modifier keys under a finger, counted because Shift has two keys.
    private var heldModifiers: [VirtualModifier: Int] = [:]
    /// Held modifiers that applied to a key while held. Releasing one of
    /// these is the end of a chord, not a tap, so it does not latch.
    private var modifiersUsedWhileHeld: Set<VirtualModifier> = []
    /// Non-modifier keys down on the host, with the modifiers sent with each.
    private var downKeys: [UInt16: [VirtualModifier]] = [:]
    /// How many down keys each host modifier is down for.
    private var hostModifiers: [VirtualModifier: Int] = [:]

    /// How long the Windows key has to be held, alone, to latch rather than
    /// be sent.
    public static let latchHoldDuration: TimeInterval = 0.5

    public init() {}

    /// Held or latched: what the next key will be sent with, and what the
    /// view lights up.
    public func isActive(_ modifier: VirtualModifier) -> Bool {
        heldModifiers[modifier, default: 0] > 0 || latches.latch(modifier) != .off
    }

    public var isAnyKeyDown: Bool { !downKeys.isEmpty }

    public func isDown(usage: UInt16) -> Bool { downKeys[usage] != nil }

    public mutating func touchDown(_ key: LaptopKey) -> [KeyboardInput] {
        switch key.kind {
        case .modifier(let modifier):
            heldModifiers[modifier, default: 0] += 1
            return []
        case .key(let usage):
            return keyDown(usage)
        case .inert:
            return []
        }
    }

    /// - Parameter heldFor: how long the finger was on the key. It only
    ///   matters for a key that `sendsWhenTappedAlone`.
    public mutating func touchUp(_ key: LaptopKey, heldFor: TimeInterval = 0) -> [KeyboardInput] {
        switch key.kind {
        case .modifier(let modifier):
            let count = heldModifiers[modifier, default: 0]
            guard count > 0 else { return [] }
            var events: [KeyboardInput] = []
            if count == 1 {
                heldModifiers[modifier] = nil
                if !modifiersUsedWhileHeld.contains(modifier) {
                    if key.sendsWhenTappedAlone,
                       latches.latch(modifier) == .off,
                       heldFor < Self.latchHoldDuration {
                        events = sendAlone(modifier)
                    } else {
                        latches.tap(modifier)
                    }
                }
                modifiersUsedWhileHeld.remove(modifier)
            } else {
                heldModifiers[modifier] = count - 1
            }
            return events
        case .key(let usage):
            return keyUp(usage)
        case .inert:
            return []
        }
    }

    /// The repeat for a key that is still down, or nil once it is not.
    public func repeatDown(usage: UInt16) -> KeyboardInput? {
        guard downKeys[usage] != nil else { return nil }
        return KeyboardInput(usage: usage, transition: .down, isRepeat: true)
    }

    /// Every up the host is owed, and every latch dropped. For the gate
    /// closing, the posture changing or the deck going away.
    public mutating func releaseAll() -> [KeyboardInput] {
        var events: [KeyboardInput] = []
        for usage in downKeys.keys.sorted() {
            events.append(KeyboardInput(usage: usage, transition: .up))
        }
        for modifier in VirtualModifier.allCases.reversed()
            where hostModifiers[modifier, default: 0] > 0 {
            events.append(KeyboardInput(usage: modifier.usage, transition: .up))
        }
        downKeys = [:]
        hostModifiers = [:]
        heldModifiers = [:]
        modifiersUsedWhileHeld = []
        latches.releaseAll()
        return events
    }

    /// The modifier pressed and released by itself, with whatever else is
    /// held or latched around it, as a real keyboard would send it.
    private mutating func sendAlone(_ modifier: VirtualModifier) -> [KeyboardInput] {
        let others = VirtualModifier.allCases.filter {
            $0 != modifier && isActive($0) && hostModifiers[$0, default: 0] == 0
        }
        latches.keyWasSent()
        return others.map { KeyboardInput(usage: $0.usage, transition: .down) }
            + [
                KeyboardInput(usage: modifier.usage, transition: .down),
                KeyboardInput(usage: modifier.usage, transition: .up),
            ]
            + others.reversed().map { KeyboardInput(usage: $0.usage, transition: .up) }
    }

    private mutating func keyDown(_ usage: UInt16) -> [KeyboardInput] {
        // A second finger on a key already down is not a second press.
        guard downKeys[usage] == nil else { return [] }
        let modifiers = VirtualModifier.allCases.filter(isActive)
        var events: [KeyboardInput] = []
        for modifier in modifiers {
            if hostModifiers[modifier, default: 0] == 0 {
                events.append(KeyboardInput(usage: modifier.usage, transition: .down))
            }
            hostModifiers[modifier, default: 0] += 1
            if heldModifiers[modifier, default: 0] > 0 {
                modifiersUsedWhileHeld.insert(modifier)
            }
        }
        downKeys[usage] = modifiers
        latches.keyWasSent()
        events.append(KeyboardInput(usage: usage, transition: .down))
        return events
    }

    private mutating func keyUp(_ usage: UInt16) -> [KeyboardInput] {
        guard let modifiers = downKeys.removeValue(forKey: usage) else { return [] }
        var events = [KeyboardInput(usage: usage, transition: .up)]
        for modifier in modifiers.reversed() {
            let count = hostModifiers[modifier, default: 0] - 1
            if count <= 0 {
                hostModifiers[modifier] = nil
                events.append(KeyboardInput(usage: modifier.usage, transition: .up))
            } else {
                hostModifiers[modifier] = count
            }
        }
        return events
    }
}
