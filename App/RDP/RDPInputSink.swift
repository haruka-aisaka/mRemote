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
final class RDPInputSink: MacInputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var native: RDPNativeSession?
    private var isAccepting = false
    /// MACRDPX features the server agreed to (MRX_CAP_*); zero for plain RDP.
    /// With MAC_KEYS and POINTER, keys, buttons and moves all go on the
    /// channel, which keeps a modifier and a click in order.
    private var macFeatures: UInt32 = 0
    /// For keys that arrive as HID usages (iPad): the modifiers they hold.
    private var modifierTracker = mrx_modifier_tracker()
    /// The modifier flags last sent, stamped on pointer events.
    private var macFlags: UInt64 = 0
    private var macButtons: UInt32 = 0
    private var lastClick: (button: UInt8, time: TimeInterval, at: PixelPoint, count: UInt16)?
    /// The bridge wants a coordinate on every event, including wheel events
    /// that have no position of their own, so the last known one is kept here
    /// rather than made up at the call site.
    private var lastPixel = PixelPoint(x: 0, y: 0)
    /// The server opened RDPEI, so a touch arrives as one.
    private var touchChannelOpen = false

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
        touchChannelOpen = false
        lastPixel = PixelPoint(x: 0, y: 0)
        resetMacStateLocked(features: 0)
        lock.unlock()
    }

    var acceptsTouch: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isAccepting && native != nil && touchChannelOpen
    }

    func setTouchChannelOpen(_ open: Bool) {
        lock.lock()
        touchChannelOpen = open
        lock.unlock()
    }

    /// The server's answer: from here on, input it agreed to goes natively.
    func setMacFeatures(_ features: UInt32) {
        lock.lock()
        resetMacStateLocked(features: features)
        lock.unlock()
    }

    private func resetMacStateLocked(features: UInt32) {
        macFeatures = features
        mrx_modifier_tracker_reset(&modifierTracker)
        macFlags = 0
        macButtons = 0
        lastClick = nil
    }

    private static let macInputFeatures = UInt32(MRX_CAP_MAC_KEYS) | UInt32(MRX_CAP_POINTER)

    var acceptsMacInput: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isAccepting && native != nil && macFeatures & Self.macInputFeatures == Self.macInputFeatures
    }

    var acceptsMacScroll: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isAccepting && native != nil && macFeatures & UInt32(MRX_CAP_PRECISE_SCROLL) != 0
    }

    var acceptsMacGestures: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isAccepting && native != nil && macFeatures & UInt32(MRX_CAP_GESTURES) != 0
    }

    func send(macGesture input: MacGestureInput) {
        lock.lock()
        guard let target = macTargetLocked(UInt32(MRX_CAP_GESTURES)) else {
            lock.unlock()
            return
        }
        let flags = input.modifierFlags == 0 ? macFlags : input.modifierFlags
        lock.unlock()
        var message = mrx_message()
        message.type = mrx_message_type(MRX_MSG_GESTURE)
        message.u.gesture.kind = input.kind.rawValue
        message.u.gesture.phase = input.phase?.rawValue ?? 0
        message.u.gesture.value = Float(input.value)
        message.u.gesture.velocity = Float(input.velocity)
        message.u.gesture.modifier_flags = flags
        target.sendMacrdpx(&message)
    }

    /// The native session to send a MACRDPX message to, if `feature` was agreed.
    private func macTargetLocked(_ feature: UInt32) -> RDPNativeSession? {
        guard isAccepting, let native, macFeatures & feature == feature else { return nil }
        return native
    }

    func send(macKey input: MacKeyInput) {
        lock.lock()
        guard let target = macTargetLocked(Self.macInputFeatures) else {
            lock.unlock()
            return
        }
        macFlags = input.modifierFlags
        lock.unlock()
        var message = mrx_message()
        message.type = mrx_message_type(MRX_MSG_KEY)
        message.u.key.keycode = input.keyCode
        message.u.key.action = mrx_key_action(input.transition == .down ? MRX_KEY_DOWN : MRX_KEY_UP)
        message.u.key.flags = input.isRepeat ? UInt8(MRX_KEY_FLAG_REPEAT) : 0
        message.u.key.modifier_flags = input.modifierFlags
        target.sendMacrdpx(&message)
    }

    func syncMacModifiers(_ flags: UInt64) {
        lock.lock()
        guard let target = macTargetLocked(Self.macInputFeatures) else {
            lock.unlock()
            return
        }
        macFlags = flags
        lock.unlock()
        var message = mrx_message()
        message.type = mrx_message_type(MRX_MSG_MODIFIERS)
        message.u.modifiers.modifier_flags = flags
        target.sendMacrdpx(&message)
    }

    func send(macScroll input: MacScrollInput) {
        lock.lock()
        guard let target = macTargetLocked(UInt32(MRX_CAP_PRECISE_SCROLL)) else {
            lock.unlock()
            return
        }
        lock.unlock()
        var message = mrx_message()
        message.type = mrx_message_type(MRX_MSG_SCROLL)
        message.u.scroll.delta_x = Float(input.deltaX)
        message.u.scroll.delta_y = Float(input.deltaY)
        message.u.scroll.unit = mrx_scroll_unit(input.isPrecise ? MRX_SCROLL_PIXEL : MRX_SCROLL_LINE)
        message.u.scroll.phase = input.phase
        message.u.scroll.momentum_phase = input.momentumPhase
        message.u.scroll.flags = input.isDirectionInvertedFromDevice ? UInt8(MRX_SCROLL_FLAG_INVERTED_FROM_DEVICE) : 0
        message.u.scroll.modifier_flags = input.modifierFlags
        target.sendMacrdpx(&message)
    }

    /// Mac mode: the pointer as a MACRDPX POINTER, or a wheel as line scroll.
    /// Returns false to let the plain RDP path handle it. Called locked.
    private func sendMacPointerLocked(_ input: PointerInput) -> Bool {
        var message = mrx_message()
        switch input {
        case .move(let pixel):
            guard let target = macTargetLocked(Self.macInputFeatures) else { return false }
            lastPixel = pixel
            message.type = mrx_message_type(MRX_MSG_POINTER)
            message.u.pointer.action = mrx_pointer_action(MRX_POINTER_MOVE)
            message.u.pointer.x = Float(pixel.x)
            message.u.pointer.y = Float(pixel.y)
            message.u.pointer.buttons_down = macButtons
            message.u.pointer.modifier_flags = macFlags
            lock.unlock()
            target.sendMacrdpx(&message)
            lock.lock()
            return true

        case let .button(button, transition, pixel):
            guard let target = macTargetLocked(Self.macInputFeatures) else { return false }
            lastPixel = pixel
            let number: UInt8 = switch button {
            case .left: UInt8(MRX_BUTTON_LEFT)
            case .right: UInt8(MRX_BUTTON_RIGHT)
            case .middle: UInt8(MRX_BUTTON_MIDDLE)
            }
            var count: UInt16 = 1
            if transition == .down {
                // The click count a Mac would give: the same button again,
                // soon and close by.
                let now = ProcessInfo.processInfo.systemUptime
                if let last = lastClick, last.button == number, now - last.time <= 0.5,
                   abs(last.at.x - pixel.x) <= 6, abs(last.at.y - pixel.y) <= 6 {
                    count = last.count &+ 1
                }
                lastClick = (number, now, pixel, count)
                macButtons |= 1 << UInt32(number)
            } else {
                count = lastClick?.button == number ? lastClick?.count ?? 1 : 1
                macButtons &= ~(1 << UInt32(number))
            }
            message.type = mrx_message_type(MRX_MSG_POINTER)
            message.u.pointer.action = mrx_pointer_action(transition == .down ? MRX_POINTER_DOWN : MRX_POINTER_UP)
            message.u.pointer.button = number
            message.u.pointer.click_count = count
            message.u.pointer.x = Float(pixel.x)
            message.u.pointer.y = Float(pixel.y)
            message.u.pointer.buttons_down = macButtons
            message.u.pointer.modifier_flags = macFlags
            lock.unlock()
            target.sendMacrdpx(&message)
            lock.lock()
            return true

        case let .scroll(horizontal, vertical):
            guard let target = macTargetLocked(UInt32(MRX_CAP_PRECISE_SCROLL)) else { return false }
            guard horizontal != 0 || vertical != 0 else { return true }
            // RDP rotation units, 120 a notch, as lines. RDP's horizontal
            // positive scrolls right; AppKit's deltaX positive scrolls left.
            message.type = mrx_message_type(MRX_MSG_SCROLL)
            message.u.scroll.unit = mrx_scroll_unit(MRX_SCROLL_LINE)
            message.u.scroll.delta_x = -Float(horizontal) / 120
            message.u.scroll.delta_y = Float(vertical) / 120
            message.u.scroll.modifier_flags = macFlags
            lock.unlock()
            target.sendMacrdpx(&message)
            lock.lock()
            return true
        }
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
        if macFeatures != 0, sendMacPointerLocked(input) {
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
        lock.lock()
        if let target = macTargetLocked(Self.macInputFeatures) {
            // A Mac server: the same key, as the Mac key in that position,
            // with the modifiers the keys so far hold.
            #if targetEnvironment(macCatalyst)
            // On the Mac, MacKeyboardCapture sends AppKit's keys as they are;
            // a usage reaching here as well would be the same key twice.
            lock.unlock()
            return
            #else
            let keyCode = mrx_keycode_for_hid_usage(input.usage)
            guard keyCode != UInt16(MRX_KEYCODE_NONE) else {
                lock.unlock()
                return
            }
            let action = mrx_key_action(input.transition == .down ? MRX_KEY_DOWN : MRX_KEY_UP)
            let flags = input.isRepeat
                ? mrx_modifier_tracker_flags(&modifierTracker)
                : mrx_modifier_tracker_update(&modifierTracker, keyCode, action)
            macFlags = flags
            lock.unlock()
            var message = mrx_message()
            message.type = mrx_message_type(MRX_MSG_KEY)
            message.u.key.keycode = keyCode
            message.u.key.action = action
            message.u.key.flags = input.isRepeat ? UInt8(MRX_KEY_FLAG_REPEAT) : 0
            message.u.key.modifier_flags = flags
            target.sendMacrdpx(&message)
            return
            #endif
        }
        lock.unlock()
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

    func send(touch: TouchInput) {
        lock.lock()
        guard isAccepting, let target = native else {
            lock.unlock()
            return
        }
        lock.unlock()
        var event = mr_rdp_touch_event()
        mr_rdp_touch_event_init(&event)
        event.contact_id = min(touch.contactID, UInt32(MR_RDP_MAX_TOUCH_CONTACT_ID))
        event.x = UInt32(max(touch.point.x, 0))
        event.y = UInt32(max(touch.point.y, 0))
        switch touch.phase {
        case .down: event.action = mr_rdp_touch_action(MR_RDP_TOUCH_DOWN)
        case .move: event.action = mr_rdp_touch_action(MR_RDP_TOUCH_MOVE)
        case .up: event.action = mr_rdp_touch_action(MR_RDP_TOUCH_UP)
        case .cancel: event.action = mr_rdp_touch_action(MR_RDP_TOUCH_CANCEL)
        }
        target.sendTouch(&event)
    }

    func send(pen: PenInput) {
        lock.lock()
        guard isAccepting, let target = native else {
            lock.unlock()
            return
        }
        lock.unlock()
        var event = mr_rdp_pen_event()
        mr_rdp_pen_event_init(&event)
        event.x = UInt32(max(pen.point.x, 0))
        event.y = UInt32(max(pen.point.y, 0))
        event.pressure = UInt32((min(max(pen.pressure, 0), 1) * Double(MR_RDP_MAX_PEN_PRESSURE)).rounded())
        event.tilt_x = Int16(min(max(pen.tiltX, -90), 90))
        event.tilt_y = Int16(min(max(pen.tiltY, -90), 90))
        event.rotation = UInt16(((pen.rotation % 360) + 360) % 360)
        switch pen.phase {
        case .hover: event.action = mr_rdp_pen_action(MR_RDP_PEN_HOVER)
        case .down: event.action = mr_rdp_pen_action(MR_RDP_PEN_DOWN)
        case .move: event.action = mr_rdp_pen_action(MR_RDP_PEN_MOVE)
        case .up: event.action = mr_rdp_pen_action(MR_RDP_PEN_UP)
        }
        var flags = mr_rdp_pen_flags(0)
        if pen.isBarrelPressed { flags |= mr_rdp_pen_flags(MR_RDP_PEN_FLAG_BARREL) }
        if pen.isEraser { flags |= mr_rdp_pen_flags(MR_RDP_PEN_FLAG_ERASER) }
        event.flags = flags
        target.sendPen(&event)
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

/// Microphone PCM to the bridge, from the audio thread, only while the
/// server has the microphone open.
final class RDPMicrophoneSink: MicrophoneSink, @unchecked Sendable {
    private let lock = NSLock()
    private var native: RDPNativeSession?
    private var isOpen = false

    func attach(_ native: RDPNativeSession?) {
        lock.lock()
        self.native = native
        isOpen = false
        lock.unlock()
    }

    func setOpen(_ open: Bool) {
        lock.lock()
        isOpen = open
        lock.unlock()
    }

    func send(pcm: Data) {
        lock.lock()
        let target = isOpen ? native : nil
        lock.unlock()
        // The bridge takes at most 64 KiB a call.
        var offset = 0
        while let target, offset < pcm.count {
            let end = min(offset + 64 * 1024, pcm.count)
            target.sendAudioCapture(pcm.subdata(in: offset..<end))
            offset = end
        }
    }
}
