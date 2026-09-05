import Foundation

/// Client-generated typematic for held keys.
///
/// RDP has no server-side auto-repeat: Windows typematic comes from the local
/// keyboard driver and is never applied to scancodes injected by a terminal
/// server, so every RDP client generates the repeat itself and sends repeated
/// key-downs followed by one key-up. iPadOS does not hand a repeat to the app
/// either - `pressesBegan`/`pressesEnded` carry physical transitions only and
/// `pressesChanged` is analog force - so without this a held Backspace deletes
/// exactly one character.
public struct KeyRepeatSettings: Hashable, Sendable, CustomStringConvertible {
    /// Below this, a stalled main run loop would queue an unbounded burst of
    /// downs, so both intervals are clamped rather than trusted.
    public static let minimumInterval: TimeInterval = 0.016

    public let isEnabled: Bool
    public let initialDelay: TimeInterval
    public let interval: TimeInterval

    public init(
        isEnabled: Bool = true,
        initialDelay: TimeInterval = 0.5,
        interval: TimeInterval = 0.05
    ) {
        self.isEnabled = isEnabled
        self.initialDelay = max(Self.minimumInterval, initialDelay)
        self.interval = max(Self.minimumInterval, interval)
    }

    /// iPadOS does not publish the system key repeat delay or rate to apps, so
    /// these are the client's own presets rather than a mirror of the device.
    public static let disabled = KeyRepeatSettings(isEnabled: false)
    public static let normal = KeyRepeatSettings(initialDelay: 0.5, interval: 0.05)
    public static let fast = KeyRepeatSettings(initialDelay: 0.3, interval: 0.03)

    public var description: String {
        guard isEnabled else { return "off" }
        return String(
            format: "delay=%.0fms interval=%.0fms",
            initialDelay * 1_000,
            interval * 1_000
        )
    }
}

/// Which usages a physical keyboard would repeat.
public enum KeyRepeatEligibility {
    /// Typematic never applies to modifiers or to lock keys, and this client
    /// also excludes the Japanese input-mode keys. LANG1/LANG2 reach the host
    /// as Convert/NonConvert, where a repeat would drive the host IME's
    /// candidate window instead of typing a character, and the keyboard
    /// contract requires exactly one down/up pair per physical press for them.
    public static func repeats(_ usage: UInt16) -> Bool {
        switch usage {
        case 0x00...0x03: return false // reserved and the rollover errors
        case 0x39: return false // Caps Lock
        case 0x47: return false // Scroll Lock
        case 0x53: return false // Num Lock
        case 0x88: return false // International2 / Kana
        case 0x8A, 0x8B: return false // International4/5 / Convert, NonConvert
        case 0x90...0x98: return false // LANG1...LANG9
        case 0xE0...0xE7: return false // modifiers
        default: return true
        }
    }
}
