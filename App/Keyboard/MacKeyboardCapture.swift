import Foundation
import InputCore
import SessionCore

/// The Mac's keyboard for the focused session, taken from AppKit.
///
/// On Mac Catalyst two kinds of key never reach `pressesBegan`: 英数/かな,
/// which UIKit dispatches to no window at all, and anything a menu item
/// claims - ⌘W closes the window instead of reaching Windows as Win+W. So on
/// the Mac the session surface reads keys one level down, from an AppKit
/// local event monitor, and consumes them there: nothing it takes reaches a
/// menu or a UIKit responder, which also means nothing reaches the surface
/// twice. The transitions it delivers are the same HID usages UIKit would
/// have produced, and they enter the arbiter as `.uiKit`, so the rest of the
/// input path - gate, quarantine, repeat, scancode mapping - is unchanged.
///
/// The right and middle mouse buttons come the same way, for a similar
/// reason: UIKit on the Mac makes a secondary click a context-menu request
/// instead of a touch.
///
/// Elsewhere (iPad, iPhone) AppKit is absent and this never installs.
@MainActor
final class MacKeyboardCapture {
    static let shared = MacKeyboardCapture()

    struct Target {
        /// Whether this surface has the keyboard right now: first responder
        /// in the key window, with input open.
        let isCapturing: @MainActor () -> Bool
        let deliver: @MainActor (UInt16, InputTransition) -> Void
        /// A right (1) or middle (2) button, pressed or released; returns
        /// whether the pointer was over this surface and the click was taken.
        let pressButton: @MainActor (UInt16, Bool) -> Bool
        /// The session's sink while a Mac server has agreed to Mac input:
        /// keys then go as Mac keys with their own modifier flags and
        /// AppKit's own repeat, instead of through the usage path.
        let macSink: @MainActor () -> (any MacInputSink)?
        /// A scroll event; returns whether the pointer was over this surface
        /// and the scroll was sent as a Mac scroll.
        let scroll: @MainActor (MacScrollInput) -> Bool
    }

    private var targets: [ObjectIdentifier: Target] = [:]
    private var monitor: Any?
    private var mouseMonitor: Any?
    private var scrollMonitor: Any?
    /// The surface Mac keys last went to, so a surface that gains the
    /// keyboard first adopts the modifiers already held.
    private var macKeyOwner: ObjectIdentifier?
    /// Keys whose down was left to the Mac, so their up is too.
    private var passedThrough: Set<UInt16> = []

    private init() {}

    func claim(_ owner: AnyObject, target: Target) {
        targets[ObjectIdentifier(owner)] = target
        installIfNeeded()
    }

    func release(_ owner: AnyObject) {
        targets[ObjectIdentifier(owner)] = nil
        if targets.isEmpty {
            if let monitor { mr_mac_key_monitor_remove(monitor) }
            if let mouseMonitor { mr_mac_key_monitor_remove(mouseMonitor) }
            if let scrollMonitor { mr_mac_key_monitor_remove(scrollMonitor) }
            monitor = nil
            mouseMonitor = nil
            scrollMonitor = nil
            macKeyOwner = nil
            passedThrough.removeAll()
        }
    }

    private func installIfNeeded() {
        #if targetEnvironment(macCatalyst)
        guard monitor == nil else { return }
        monitor = mr_mac_key_monitor_install { type, keyCode, flags, isRepeat in
            // AppKit calls local monitors on the main thread.
            MainActor.assumeIsolated {
                MacKeyboardCapture.shared.handle(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat)
            }
        }
        // UIKit on the Mac turns a secondary click into a context-menu
        // request rather than a touch, and drops the middle button; the
        // surface takes both here, at the pointer it is already tracking.
        mouseMonitor = mr_mac_mouse_monitor_install { button, pressed in
            MainActor.assumeIsolated {
                MacKeyboardCapture.shared.targets.values.contains { $0.pressButton(button, pressed) }
            }
        }
        // A Mac server takes the trackpad's own scrolling - pixel deltas,
        // gesture and momentum phases - where UIKit would only give a pan.
        scrollMonitor = mr_mac_scroll_monitor_install { dx, dy, precise, phase, momentum, inverted, flags in
            MainActor.assumeIsolated {
                let input = MacScrollInput(
                    deltaX: dx, deltaY: dy, isPrecise: precise, phase: phase,
                    momentumPhase: momentum, isDirectionInvertedFromDevice: inverted,
                    modifierFlags: MacVirtualKey.withDeviceFlags(flags))
                return MacKeyboardCapture.shared.targets.values.contains { $0.scroll(input) }
            }
        }
        #endif
    }

    /// Returns whether the event was taken for the session.
    private func handle(type: MRMacKeyEventType, keyCode: UInt16, flags: UInt64, isRepeat: Bool) -> Bool {
        guard let entry = targets.first(where: { $0.value.isCapturing() }) else {
            passedThrough.removeAll()
            return false
        }
        let (owner, target) = (entry.key, entry.value)
        if let sink = target.macSink(), sink.acceptsMacInput {
            return handleMac(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat,
                             owner: owner, sink: sink)
        }
        macKeyOwner = nil
        switch type {
        case .keyDown, .keyUp:
            if type == .keyUp, passedThrough.remove(keyCode) != nil { return false }
            let command = flags & Self.commandFlag != 0
            let control = flags & Self.controlFlag != 0
            if type == .keyDown, MacVirtualKey.isReservedForMac(keyCode: keyCode, command: command, control: control) {
                passedThrough.insert(keyCode)
                return false
            }
            guard let usage = MacVirtualKey.usage(for: keyCode) else { return false }
            // The surface makes its own repeat, as on the iPad, so AppKit's
            // auto-repeated downs are only swallowed.
            if !isRepeat {
                target.deliver(usage, type == .keyDown ? .down : .up)
            }
            return true

        case .flagsChanged:
            if keyCode == MacVirtualKey.capsLock {
                target.deliver(Self.capsLockUsage, .down)
                target.deliver(Self.capsLockUsage, .up)
                return true
            }
            guard let modifier = MacVirtualKey.modifier(for: keyCode) else { return false }
            target.deliver(modifier.usage, MacVirtualKey.isModifierDown(modifier, flags: flags) ? .down : .up)
            return true

        @unknown default:
            return false
        }
    }

    /// A Mac server: the key as it is. Only the Mac's own reserved shortcuts
    /// stay here; everything else - ⌘W, ⌘Space, Fn - goes to the host Mac.
    private func handleMac(
        type: MRMacKeyEventType, keyCode: UInt16, flags: UInt64, isRepeat: Bool,
        owner: ObjectIdentifier, sink: any MacInputSink
    ) -> Bool {
        let flags = MacVirtualKey.withDeviceFlags(flags)
        if macKeyOwner != owner {
            macKeyOwner = owner
            sink.syncMacModifiers(MacVirtualKey.withDeviceFlags(mr_mac_current_modifier_flags()))
        }
        switch type {
        case .keyDown, .keyUp:
            if type == .keyUp, passedThrough.remove(keyCode) != nil { return false }
            if type == .keyDown, MacVirtualKey.isReservedForMac(
                keyCode: keyCode, command: flags & Self.commandFlag != 0, control: flags & Self.controlFlag != 0) {
                passedThrough.insert(keyCode)
                return false
            }
            sink.send(macKey: MacKeyInput(
                keyCode: keyCode, transition: type == .keyDown ? .down : .up,
                isRepeat: isRepeat, modifierFlags: flags))
            return true

        case .flagsChanged:
            let down: Bool
            if keyCode == MacVirtualKey.capsLock {
                down = true   // each change of state is one press
            } else if keyCode == MacVirtualKey.function {
                down = flags & MacVirtualKey.functionFlag != 0
            } else if let modifier = MacVirtualKey.modifier(for: keyCode) {
                down = MacVirtualKey.isModifierDown(modifier, flags: flags)
            } else {
                return false
            }
            sink.send(macKey: MacKeyInput(keyCode: keyCode, transition: down ? .down : .up, modifierFlags: flags))
            return true

        @unknown default:
            return false
        }
    }

    /// The surface lost the keyboard: whatever the host still holds is let go.
    func releaseMacKeys(for owner: AnyObject) {
        guard macKeyOwner == ObjectIdentifier(owner) else { return }
        macKeyOwner = nil
        targets[ObjectIdentifier(owner)]?.macSink()?.syncMacModifiers(0)
    }

    private static let commandFlag: UInt64 = 1 << 20 // NSEvent.ModifierFlags.command
    private static let controlFlag: UInt64 = 1 << 18 // NSEvent.ModifierFlags.control
    private static let capsLockUsage: UInt16 = 0x39
}
