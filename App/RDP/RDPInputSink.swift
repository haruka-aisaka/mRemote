import Foundation
import RDPProtocol
import SessionCore

/// Carries pointer input from the surface to the bridge without going through
/// the session actor.
///
/// docs/architecture.md keeps input on the data plane for the same reason it
/// keeps frames there: a pointer move arrives on the main thread from a UIKit
/// callback, and awaiting an actor for each one would serialise it behind
/// every state change and lose the capture order. `send` therefore runs
/// synchronously on the calling thread; all it does is validate, build the C
/// struct and push it into the bridge's own bounded queue, which the session
/// worker drains.
///
/// The session actor owns this object and is the only thing that changes which
/// native session it points at, so a send that races a reconnect either
/// reaches the current worker or is dropped - never the previous one.
final class RDPInputSink: DesktopInputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var native: RDPNativeSession?
    private var isAccepting = false
    /// The bridge wants a coordinate on every event, including wheel events
    /// that have no position of their own, so the last known one is kept here
    /// rather than made up at the call site.
    private var lastPixel = PixelPoint(x: 0, y: 0)

    var acceptsInput: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isAccepting && native != nil
    }

    /// Called by the session when an attempt starts and when its worker ends.
    func attach(_ native: RDPNativeSession?) {
        lock.lock()
        self.native = native
        if native == nil { isAccepting = false }
        lastPixel = PixelPoint(x: 0, y: 0)
        lock.unlock()
    }

    /// Input is only delivered while the session is connected. A press sent
    /// during the handshake would be discarded by the server anyway, and a
    /// press sent while disconnecting would be a release that never lands.
    func setAccepting(_ accepting: Bool) {
        lock.lock()
        isAccepting = accepting
        lock.unlock()
    }

    func send(_ input: PointerInput) {
        lock.lock()
        guard isAccepting, let native else {
            lock.unlock()
            return
        }
        var event = mr_rdp_pointer_event()
        mr_rdp_pointer_event_init(&event)

        switch input {
        case .move(let pixel):
            lastPixel = pixel
            event.kind = mr_rdp_pointer_kind(MR_RDP_POINTER_MOVE)
        case let .button(button, transition, pixel):
            lastPixel = pixel
            event.kind = mr_rdp_pointer_kind(MR_RDP_POINTER_BUTTON)
            event.button = Self.nativeButton(button)
            event.action = mr_rdp_key_action(
                transition == .down ? MR_RDP_KEY_DOWN : MR_RDP_KEY_UP
            )
        case let .scroll(horizontal, vertical):
            guard horizontal != 0 || vertical != 0 else {
                lock.unlock()
                return
            }
            event.kind = mr_rdp_pointer_kind(MR_RDP_POINTER_WHEEL)
            event.wheel_x = Self.clampWheel(horizontal)
            event.wheel_y = Self.clampWheel(vertical)
        }
        event.x = UInt32(max(lastPixel.x, 0))
        event.y = UInt32(max(lastPixel.y, 0))
        let target = native
        lock.unlock()

        // Outside the lock: the gate has its own, and holding two locks across
        // a call into C is how a teardown deadlocks.
        target.sendPointer(&event)
    }

    /// A usage this build cannot map is dropped here, which is the only place
    /// that knows RDP's scan code table. `RDPScanCodeMapper` refuses rather
    /// than guesses, because a wrong scan code types the wrong character on
    /// someone's machine while an unmapped key merely does nothing.
    func send(_ input: KeyboardInput) {
        guard let scanCode = try? RDPScanCodeMapper.set1ScanCode(forHIDUsage: input.usage) else {
            return
        }
        lock.lock()
        guard isAccepting, let target = native else {
            lock.unlock()
            return
        }
        lock.unlock()

        var event = mr_rdp_key_event()
        mr_rdp_key_event_init(&event)
        event.code = UInt16(scanCode.value)
        event.extended = scanCode.isExtended ? 1 : 0
        event.extended1 = 0
        event.action = mr_rdp_key_action(
            input.transition == .down ? MR_RDP_KEY_DOWN : MR_RDP_KEY_UP
        )
        target.sendKey(&event)
    }

    func send(unicode codeUnit: UInt16) {
        lock.lock()
        guard isAccepting, let target = native else {
            lock.unlock()
            return
        }
        lock.unlock()
        target.sendUnicode(codeUnit)
    }

    /// The bridge caps each axis and splits a larger delta across PDUs, but it
    /// rejects an out-of-range value outright, so the clamp happens here too.
    private static func clampWheel(_ value: Int32) -> Int32 {
        min(max(value, -Int32(MR_RDP_MAX_WHEEL_DELTA)), Int32(MR_RDP_MAX_WHEEL_DELTA))
    }

    private static func nativeButton(_ button: PointerButton) -> mr_rdp_pointer_button {
        switch button {
        case .left: return mr_rdp_pointer_button(MR_RDP_POINTER_BUTTON_LEFT)
        case .right: return mr_rdp_pointer_button(MR_RDP_POINTER_BUTTON_RIGHT)
        case .middle: return mr_rdp_pointer_button(MR_RDP_POINTER_BUTTON_MIDDLE)
        }
    }
}
