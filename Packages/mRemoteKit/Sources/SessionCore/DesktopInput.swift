import Foundation

public enum PointerButton: String, Hashable, Sendable, CaseIterable {
    case left
    case right
    case middle
}

/// A key and a pointer button have exactly the same two states, so they share
/// one type rather than two identical ones.
public enum InputTransition: Hashable, Sendable {
    case down
    case up
}

/// One thing to send to the remote desktop's pointer.
///
/// Scroll carries RDP rotation units rather than device points: quantising
/// belongs upstream in `InputCore`, where the fractional remainder between two
/// events can be kept, and by the time an input reaches a session it should
/// need no further interpretation.
public enum PointerInput: Hashable, Sendable {
    case move(PixelPoint)
    case button(PointerButton, InputTransition, at: PixelPoint)
    case scroll(horizontal: Int32, vertical: Int32)
}

/// One physical key transition, as the platform reported it.
///
/// The usage is a USB HID keyboard-page usage, which is protocol-independent
/// on purpose: turning it into a scan code is the RDP layer's job, and a
/// future SSH terminal would want the same event mapped a different way
/// entirely. docs/architecture.md section 4 puts the boundary exactly here.
public struct KeyboardInput: Hashable, Sendable {
    public let usage: UInt16
    public let transition: InputTransition
    /// True for a client-generated typematic repeat rather than a physical
    /// press. Only ever `.down`: the single up stays bound to the physical
    /// release so the remote never sees a transition to unwind.
    public let isRepeat: Bool

    public init(usage: UInt16, transition: InputTransition, isRepeat: Bool = false) {
        self.usage = usage
        self.transition = transition
        self.isRepeat = isRepeat
    }
}

/// One finger on the remote touch screen, for a session that sends touches
/// rather than a pointer.
public struct TouchInput: Hashable, Sendable {
    public enum Phase: Hashable, Sendable {
        case down, move, up, cancel
    }

    /// Stable while the finger is down; reused afterwards.
    public let contactID: UInt32
    public let phase: Phase
    public let point: PixelPoint

    public init(contactID: UInt32, phase: Phase, point: PixelPoint) {
        self.contactID = contactID
        self.phase = phase
        self.point = point
    }
}

/// The pen, as a pen: pressure, tilt and its buttons.
public struct PenInput: Hashable, Sendable {
    public enum Phase: Hashable, Sendable {
        case hover, down, move, up
    }

    public let phase: Phase
    public let point: PixelPoint
    /// 0...1.
    public let pressure: Double
    /// Degrees, -90...90.
    public let tiltX: Int
    public let tiltY: Int
    /// Degrees, 0...359.
    public let rotation: Int
    public let isBarrelPressed: Bool
    public let isEraser: Bool

    public init(
        phase: Phase,
        point: PixelPoint,
        pressure: Double = 0,
        tiltX: Int = 0,
        tiltY: Int = 0,
        rotation: Int = 0,
        isBarrelPressed: Bool = false,
        isEraser: Bool = false
    ) {
        self.phase = phase
        self.point = point
        self.pressure = pressure
        self.tiltX = tiltX
        self.tiltY = tiltY
        self.rotation = rotation
        self.isBarrelPressed = isBarrelPressed
        self.isEraser = isEraser
    }
}

/// Where input goes on its way to the remote host.
///
/// Deliberately not part of the session actor. docs/architecture.md keeps the
/// input path on the data plane: a pointer move arrives on the main thread
/// from a UIKit callback, and hopping to an actor for each one would both
/// serialise it behind every state change and lose the capture order, because
/// independent tasks have none. `send` is therefore synchronous, non-blocking
/// and safe to call from the event handler itself; the bounded queue that
/// absorbs a burst lives in the C bridge, which is where the worker that
/// drains it also lives.
///
/// It is class-bound because a sink is a long-lived thing with identity that
/// the session retargets across reconnects, and the surface has to be able to
/// tell that it has been handed a different one.
public protocol DesktopInputSink: AnyObject, Sendable {
    /// True only while the session can actually deliver input. A caller is
    /// expected to check this to decide whether to track state, not to guard
    /// `send`: `send` is always safe and drops what it cannot deliver.
    var acceptsInput: Bool { get }

    func send(_ input: PointerInput)

    /// A key that this build cannot map is dropped here rather than refused
    /// upstream: which usages an RDP session can carry is the RDP layer's
    /// knowledge, not the surface's.
    func send(_ input: KeyboardInput)

    /// One UTF-16 code unit of committed text, typed as a Unicode key event.
    /// The software keyboard's local IME mode is the only producer: physical
    /// keys always travel as `KeyboardInput`.
    func send(unicode codeUnit: UInt16)

    /// Touch and pen, for a session that can carry them. Dropped otherwise.
    func send(touch: TouchInput)
    func send(pen: PenInput)
}

public extension DesktopInputSink {
    func send(touch: TouchInput) {}
    func send(pen: PenInput) {}
}
