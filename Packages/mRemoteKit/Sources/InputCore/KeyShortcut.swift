import Foundation
import SessionCore

/// A key a shortcut can end in, by HID usage, with the name it is shown by.
public struct ShortcutKey: Hashable, Sendable, Identifiable {
    public let usage: UInt16
    public let name: String

    public var id: UInt16 { usage }

    public init(usage: UInt16, name: String) {
        self.usage = usage
        self.name = name
    }

    /// Every key the shortcut editor offers: positions, not characters, so a
    /// letter is the key that types it on a US layout.
    public static let all: [ShortcutKey] = letters + digits + functionKeys + named

    public static let letters: [ShortcutKey] = (0..<26).map { offset in
        ShortcutKey(usage: UInt16(0x04 + offset), name: String(UnicodeScalar(UInt8(0x41 + offset))))
    }

    public static let digits: [ShortcutKey] = (1...9).map {
        ShortcutKey(usage: UInt16(0x1E + $0 - 1), name: "\($0)")
    } + [ShortcutKey(usage: 0x27, name: "0")]

    public static let functionKeys: [ShortcutKey] = (1...12).map {
        ShortcutKey(usage: UInt16(0x3A + $0 - 1), name: "F\($0)")
    }

    public static let named: [ShortcutKey] = [
        ShortcutKey(usage: 0x29, name: "Esc"),
        ShortcutKey(usage: 0x2B, name: "Tab"),
        ShortcutKey(usage: 0x28, name: "Enter"),
        ShortcutKey(usage: 0x2C, name: "Space"),
        ShortcutKey(usage: 0x2A, name: "Backspace"),
        ShortcutKey(usage: 0x4C, name: "Delete"),
        ShortcutKey(usage: 0x49, name: "Insert"),
        ShortcutKey(usage: 0x4A, name: "Home"),
        ShortcutKey(usage: 0x4D, name: "End"),
        ShortcutKey(usage: 0x4B, name: "PageUp"),
        ShortcutKey(usage: 0x4E, name: "PageDown"),
        ShortcutKey(usage: 0x52, name: "↑"),
        ShortcutKey(usage: 0x51, name: "↓"),
        ShortcutKey(usage: 0x50, name: "←"),
        ShortcutKey(usage: 0x4F, name: "→"),
        ShortcutKey(usage: 0x46, name: "PrintScreen"),
        ShortcutKey(usage: 0x48, name: "Pause"),
        ShortcutKey(usage: 0x2D, name: "-"),
        ShortcutKey(usage: 0x2E, name: "="),
        ShortcutKey(usage: 0x36, name: ","),
        ShortcutKey(usage: 0x37, name: "."),
        ShortcutKey(usage: 0x38, name: "/"),
        ShortcutKey(usage: 0x35, name: "半角/全角"),
        ShortcutKey(usage: 0x8B, name: "無変換"),
        ShortcutKey(usage: 0x8A, name: "変換"),
    ]

    public static func named(usage: UInt16) -> ShortcutKey? {
        all.first { $0.usage == usage }
    }
}

/// A key with modifiers, sent in one tap: Ctrl+Alt+Del, Win+R and the like.
public struct KeyShortcut: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    /// Empty to be shown by its keys.
    public var title: String
    public var modifiers: Set<VirtualModifier>
    public var usage: UInt16

    public init(id: UUID = UUID(), title: String = "", modifiers: Set<VirtualModifier>, usage: UInt16) {
        self.id = id
        self.title = title
        self.modifiers = modifiers
        self.usage = usage
    }

    /// Ctrl+Alt+Del: the modifiers in the order Windows writes them.
    public var keysDescription: String {
        let names = orderedModifiers.map(\.displayName)
        let key = ShortcutKey.named(usage: usage)?.name ?? String(format: "0x%02X", usage)
        return (names + [key]).joined(separator: "+")
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, modifiers, usage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        modifiers = Set(try container.decode([VirtualModifier].self, forKey: .modifiers))
        usage = try container.decode(UInt16.self, forKey: .usage)
    }

    /// The modifiers as a sorted list, so the same shortcut is always the
    /// same string: a stored value that changed on every write would look
    /// like an edit to anything watching it.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(orderedModifiers, forKey: .modifiers)
        try container.encode(usage, forKey: .usage)
    }

    private var orderedModifiers: [VirtualModifier] {
        VirtualModifier.allCases
            .sorted { $0.displayOrder < $1.displayOrder }
            .filter(modifiers.contains)
    }

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? keysDescription : trimmed
    }

    /// Modifiers down, the key down and up, modifiers up in reverse: whole
    /// in itself, so nothing is left held on the host.
    public var inputs: [KeyboardInput] {
        let held = orderedModifiers.map(\.usage)
        return held.map { KeyboardInput(usage: $0, transition: .down) }
            + [KeyboardInput(usage: usage, transition: .down), KeyboardInput(usage: usage, transition: .up)]
            + held.reversed().map { KeyboardInput(usage: $0, transition: .up) }
    }

    /// Offered in the editor to add with one tap; the first few are where a
    /// new install starts.
    public static let suggestions: [KeyShortcut] = [
        KeyShortcut(modifiers: [.control, .alt], usage: 0x4C),
        KeyShortcut(modifiers: [.control, .shift], usage: 0x29),
        KeyShortcut(modifiers: [.windows], usage: 0x15),
        KeyShortcut(modifiers: [.alt], usage: 0x2B),
        KeyShortcut(modifiers: [.alt], usage: 0x3D),
        KeyShortcut(modifiers: [.windows], usage: 0x07),
        KeyShortcut(modifiers: [.windows], usage: 0x08),
        KeyShortcut(modifiers: [.windows, .shift], usage: 0x16),
        KeyShortcut(modifiers: [.control], usage: 0x06),
        KeyShortcut(modifiers: [.control], usage: 0x19),
        KeyShortcut(modifiers: [.control], usage: 0x1D),
        KeyShortcut(modifiers: [.control], usage: 0x04),
    ]

    public static var defaults: [KeyShortcut] { Array(suggestions.prefix(4)) }

    /// For a Mac host, where Win is ⌘ and Alt is ⌥: the shortcuts a touch
    /// screen has no other way to send.
    public static let macDefaults: [KeyShortcut] = [
        KeyShortcut(title: "⌘Tab", modifiers: [.windows], usage: 0x2B),
        KeyShortcut(title: "⌘Space", modifiers: [.windows], usage: 0x2C),
        KeyShortcut(title: "⌃↑", modifiers: [.control], usage: 0x52),
        KeyShortcut(title: "⌥⌘Esc", modifiers: [.windows, .alt], usage: 0x29),
        KeyShortcut(title: "⌃⌘Q", modifiers: [.control, .windows], usage: 0x14),
    ]
}

public extension VirtualModifier {
    var displayName: String {
        switch self {
        case .control: return "Ctrl"
        case .alt: return "Alt"
        case .shift: return "Shift"
        case .windows: return "Win"
        }
    }

    /// Ctrl, Win, Alt, Shift - the order Windows' own documentation uses.
    var displayOrder: Int {
        switch self {
        case .control: return 0
        case .windows: return 1
        case .alt: return 2
        case .shift: return 3
        }
    }
}

extension VirtualModifier: Codable {}

/// The user's shortcuts as stored: JSON in one defaults string, so
/// `@AppStorage` can hold and observe it.
public struct KeyShortcutList: Hashable, Sendable, RawRepresentable {
    public var shortcuts: [KeyShortcut]

    public static let storageKey = "custom-shortcuts"

    public init(_ shortcuts: [KeyShortcut]) {
        self.shortcuts = shortcuts
    }

    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let shortcuts = try? JSONDecoder().decode([KeyShortcut].self, from: data) else { return nil }
        self.shortcuts = shortcuts
    }

    public var rawValue: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(shortcuts) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    public static var standard: KeyShortcutList { KeyShortcutList(KeyShortcut.defaults) }
}
