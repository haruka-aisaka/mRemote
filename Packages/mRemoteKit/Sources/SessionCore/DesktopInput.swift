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
}
