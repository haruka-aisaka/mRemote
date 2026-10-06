import GameController
import InputCore

/// The `GCKeyboard` side of docs/input-design.md section 4.2.
///
/// One per process, because `GCKeyboard.coalesced` is one per process. It
/// never sends anything to a session itself: it reports to the surface that
/// most recently claimed it, and that surface's `KeyboardEventArbiter`
/// decides whether the observation is the one bound to the usage or only
/// physical state. A surface that is not focused still receives reports, which
/// is how a quarantine can clear while a menu is open.
@MainActor
final class HardwareKeyboardMonitor {
    static let shared = HardwareKeyboardMonitor()

    /// Receives each transition and each disconnect. Weakly held through the
    /// closure's owner, so a surface that goes away is simply not called.
    struct Target {
        let onKey: @MainActor (UInt16, Bool) -> Void
        let onDisconnect: @MainActor () -> Void
    }

    private var targets: [ObjectIdentifier: Target] = [:]
    private var order: [ObjectIdentifier] = []
    private var observers: [NSObjectProtocol] = []
    private(set) var isKeyboardConnected = false

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .GCKeyboardDidConnect, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.attach() }
        })
        observers.append(center.addObserver(
            forName: .GCKeyboardDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.detach() }
        })
        attach()
    }

    /// The newest claim wins: the surface on screen is the last one built.
    func claim(_ owner: AnyObject, target: Target) {
        let key = ObjectIdentifier(owner)
        targets[key] = target
        order.removeAll { $0 == key }
        order.append(key)
    }

    func release(_ owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        targets[key] = nil
        order.removeAll { $0 == key }
    }

    /// What the keyboard says is held right now, or nil with no keyboard.
    /// `isPressed` is authoritative even for presses whose transitions went to
    /// another app, which is what makes it worth asking.
    func physicallyHeldUsages() -> Set<UInt16>? {
        guard let input = GCKeyboard.coalesced?.keyboardInput else { return nil }
        guard input.isAnyKeyPressed else { return [] }
        var held: Set<UInt16> = []
        for usage in UInt16(0x04)...UInt16(0xE7) {
            if input.button(forKeyCode: GCKeyCode(rawValue: CFIndex(usage)))?.isPressed == true {
                held.insert(usage)
            }
        }
        return held
    }

    private var currentTarget: Target? {
        order.last.flatMap { targets[$0] }
    }

    private func attach() {
        guard let input = GCKeyboard.coalesced?.keyboardInput else { return }
        isKeyboardConnected = true
        input.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            // Delivered on the main queue, GameController's default.
            MainActor.assumeIsolated {
                guard let usage = UInt16(exactly: keyCode.rawValue) else { return }
                self?.currentTarget?.onKey(usage, pressed)
            }
        }
    }

    private func detach() {
        isKeyboardConnected = GCKeyboard.coalesced != nil
        for key in order {
            targets[key]?.onDisconnect()
        }
        if isKeyboardConnected { attach() }
    }
}
