import Foundation

/// Client-generated typematic for held keys.
///
/// RDP has no server-side auto-repeat. Windows typematic is produced by the
/// local keyboard driver and is never applied to scancodes injected by a
/// terminal server, so every RDP client generates the repeat itself and sends
/// repeated key-down scancodes followed by a single key-up. iPadOS does not
/// hand a repeat to this app either: `pressesBegan`/`pressesEnded` carry only
/// physical transitions, `pressesChanged` is analog force, and
/// `GCKeyboard.keyChangedHandler` fires only on a state change. The repeat
/// therefore has to originate here.
///
/// The bridge already expects the resulting stream: `mr_input_command_queue`
/// treats a repeated down as one that "does not create another reservation",
/// so a repeat never adds a release the teardown path would have to drain.
struct KeyRepeatSettings: Equatable, Sendable, CustomStringConvertible {
    /// Below this a stalled main run loop would queue an unbounded burst of
    /// downs, so both intervals are clamped rather than trusted.
    static let minimumInterval: TimeInterval = 0.016

    let isEnabled: Bool
    let initialDelay: TimeInterval
    let interval: TimeInterval

    init(
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
    static let disabled = KeyRepeatSettings(isEnabled: false)
    static let normal = KeyRepeatSettings(initialDelay: 0.5, interval: 0.05)
    static let fast = KeyRepeatSettings(initialDelay: 0.3, interval: 0.03)

    var description: String {
        guard isEnabled else { return "off" }
        return String(
            format: "delay=%.0fms interval=%.0fms",
            initialDelay * 1_000,
            interval * 1_000
        )
    }
}

/// Which usages a physical keyboard would repeat.
enum KeyRepeatEligibility {
    /// Typematic never applies to modifiers or to lock keys, and this client
    /// also excludes the Japanese input-mode keys. LANG1/LANG2 reach the host
    /// as Convert/NonConvert, where a repeat would drive the host IME's
    /// candidate window instead of typing a character, and the keyboard
    /// contract requires exactly one down/up pair per physical press for them.
    static func repeats(_ usage: UInt16) -> Bool {
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

/// One pending fire at a time. Injected so the arbiter's repeat behaviour is
/// testable without waiting on wall-clock time.
@MainActor
protocol KeyRepeatTimer: AnyObject {
    /// Replaces any pending fire.
    func schedule(after delay: TimeInterval, _ fire: @escaping @MainActor () -> Void)
    func cancel()
}

@MainActor
final class RunLoopKeyRepeatTimer: KeyRepeatTimer {
    private var timer: Timer?

    /// Nonisolated so it can be a default argument of a main-actor initializer.
    /// It touches no isolated state beyond `timer`'s nil default.
    nonisolated init() {}

    func schedule(after delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) {
        cancel()
        // .common so a held key keeps repeating while a gesture is tracking.
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            // A timer added to the main run loop always fires on the main
            // thread, which is the main actor's executor.
            MainActor.assumeIsolated { fire() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}
