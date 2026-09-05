import Foundation

public enum PointerButton: String, Hashable, Sendable, CaseIterable {
    case left
    case right
    case middle
}

public enum ButtonTransition: Hashable, Sendable {
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
    case button(PointerButton, ButtonTransition, at: PixelPoint)
    case scroll(horizontal: Int32, vertical: Int32)
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
}
