import Foundation

/// The data plane between a protocol worker and the renderer.
///
/// docs/architecture.md section 6 keeps frames off the control stream: a
/// desktop has no history worth replaying, so only the newest surface is kept
/// and the damage the renderer has not drawn yet accumulates on top of it.
/// The worker is never blocked by a renderer that is behind, and the renderer
/// never wakes for a frame that a newer one has already replaced.
public final class LatestDesktopFrameStore: @unchecked Sendable {
    public typealias Signal = @Sendable () -> Void

    private let lock = NSLock()
    private var pending: DesktopFrame?
    private var signal: Signal?
    /// True between raising a signal and the consume that answers it. It is
    /// what makes a burst of frames wake the renderer once instead of once
    /// per frame.
    private var signalPending = false
    private var submittedCount = 0
    private var coalescedCount = 0
    private var lastDesktopSize: (width: Int, height: Int)?

    public init() {}

    /// Set by the renderer when it attaches. Replacing it while a signal is
    /// outstanding re-raises it, so a surface that attaches late still draws
    /// the frame that arrived before it existed.
    public func setSignal(_ signal: Signal?) {
        lock.lock()
        self.signal = signal
        let shouldRaise = signalPending && pending != nil
        lock.unlock()
        if shouldRaise { signal?() }
    }

    /// Called on the protocol worker. Never blocks on the renderer.
    public func submit(_ frame: DesktopFrame) {
        lock.lock()
        submittedCount += 1
        if let previous = pending {
            coalescedCount += 1
            pending = frame.withDamage(Self.coalescedDamage(replacing: previous, with: frame))
        } else {
            pending = frame
        }
        lastDesktopSize = (frame.width, frame.height)
        let shouldRaise = !signalPending
        signalPending = true
        let signal = self.signal
        lock.unlock()

        // Outside the lock: the renderer's signal may synchronously hop to the
        // main actor, and the worker must not hold this lock across that.
        if shouldRaise { signal?() }
    }

    /// Called on the renderer. Returns nil when nothing new has arrived.
    public func consume() -> DesktopFrame? {
        lock.lock()
        let frame = pending
        pending = nil
        signalPending = false
        lock.unlock()
        return frame
    }

    /// Drops the pending frame without drawing it. Used when a session is put
    /// in the background: keeping the bytes alive for a surface nobody is
    /// looking at is exactly the memory the visibility policy exists to
    /// release.
    public func discardPending() {
        lock.lock()
        pending = nil
        signalPending = false
        lock.unlock()
    }

    public var desktopSize: (width: Int, height: Int)? {
        lock.lock()
        defer { lock.unlock() }
        return lastDesktopSize
    }

    /// Counters for the diagnostics view. A rising coalesced share means the
    /// renderer is behind the server, which is the number worth watching
    /// during a 30 minute session.
    public var statistics: (submitted: Int, coalesced: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (submittedCount, coalescedCount)
    }

    /// Two frames' damage combined into what the renderer still owes.
    ///
    /// The union of the two bounding boxes is used rather than the exact set:
    /// a hundred small rectangles per frame would make the upload loop cost
    /// more than the pixels it saves, and any frame whose surface changed
    /// shape cannot have its damage related to the previous one at all.
    static func coalescedDamage(
        replacing previous: DesktopFrame,
        with newest: DesktopFrame
    ) -> [PixelRect] {
        guard previous.describesSameSurface(as: newest),
              let previousDamage = boundingRectangle(previous.dirtyRectangles),
              let newestDamage = boundingRectangle(newest.dirtyRectangles) else {
            return []
        }
        let combined = previousDamage.union(newestDamage)
        return combined == newest.desktopRectangle ? [] : [combined]
    }

    private static func boundingRectangle(_ rectangles: [PixelRect]) -> PixelRect? {
        guard var result = rectangles.first else { return nil }
        for rectangle in rectangles.dropFirst() {
            result = result.union(rectangle)
        }
        return result
    }
}
