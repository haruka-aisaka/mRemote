import Foundation
import SessionCore

/// Normalises what a pointing device did into what the remote host is told.
///
/// It holds the state that makes the difference between a pointer that works
/// and one that leaves a button stuck down on the server: which buttons this
/// side believes are pressed, where the pointer last was, and the scroll
/// remainder. Nothing here is UIKit, so all of that is testable on the host,
/// and the view above it only has to report events.
public struct PointerInputRouter: Sendable {
    /// The viewport geometry the local points are interpreted against. The
    /// surface replaces it whenever it lays out, zooms or the desktop resizes.
    public var transform: ViewportTransform

    public private(set) var pressedButtons: Set<PointerButton> = []
    public private(set) var lastPixel = PixelPoint(x: 0, y: 0)
    private var hasLastPixel = false
    private var accumulator: ScrollWheelAccumulator

    public init(transform: ViewportTransform, scrollDirection: ScrollDirection = .normal) {
        self.transform = transform
        self.accumulator = ScrollWheelAccumulator(direction: scrollDirection)
    }

    public var scrollDirection: ScrollDirection { accumulator.direction }

    public mutating func setScrollDirection(_ direction: ScrollDirection) {
        accumulator.setDirection(direction)
    }

    /// A pointer move. Repeating the same desktop pixel produces nothing: the
    /// remote host learns nothing from it, and a trackpad reports far more
    /// positions than a 1080p desktop has pixels.
    public mutating func moved(to local: ViewportPoint) -> [PointerInput] {
        let pixel = transform.remotePixel(fromLocal: local)
        guard !hasLastPixel || pixel != lastPixel else { return [] }
        lastPixel = pixel
        hasLastPixel = true
        return [.move(pixel)]
    }

    /// A move to a desktop pixel computed elsewhere: the on-screen trackpad
    /// moves the pointer relatively, so there is no local point to map.
    public mutating func moved(toPixel pixel: PixelPoint) -> [PointerInput] {
        guard !hasLastPixel || pixel != lastPixel else { return [] }
        lastPixel = pixel
        hasLastPixel = true
        return [.move(pixel)]
    }

    /// Where the remote pointer is, when this side has said so.
    public var knownPixel: PixelPoint? { hasLastPixel ? lastPixel : nil }

    /// The full set of buttons now held. Reporting the set rather than one
    /// transition is what makes a chord change safe: the platform tells us
    /// what is pressed now, and anything this side thought was pressed and is
    /// missing has to be released whether or not its release was observed.
    ///
    /// Releases are emitted before presses, so a gesture that swaps buttons in
    /// one event never has both down on the server at once.
    public mutating func buttonsChanged(
        to buttons: Set<PointerButton>,
        at local: ViewportPoint? = nil
    ) -> [PointerInput] {
        var events: [PointerInput] = []
        if let local {
            events.append(contentsOf: moved(to: local))
        }
        let pixel = lastPixel
        for button in PointerButton.allCases where pressedButtons.contains(button)
            && !buttons.contains(button) {
            events.append(.button(button, .up, at: pixel))
        }
        for button in PointerButton.allCases where buttons.contains(button)
            && !pressedButtons.contains(button) {
            events.append(.button(button, .down, at: pixel))
        }
        pressedButtons = buttons
        return events
    }

    /// Device points, positive vertical meaning the fingers moved down.
    public mutating func scrolled(horizontal: Double, vertical: Double) -> [PointerInput] {
        let delta = accumulator.consume(horizontal: horizontal, vertical: vertical)
        guard !delta.isZero else { return [] }
        return [.scroll(horizontal: delta.horizontal, vertical: delta.vertical)]
    }

    /// Releases everything this side believes is held.
    ///
    /// docs/architecture.md section 10 calls for this on focus loss, session
    /// switch and scene deactivation. Without it a click that begins here and
    /// ends somewhere the app never sees leaves the button down on Windows,
    /// which turns the next move into a drag across the desktop.
    public mutating func releaseAll() -> [PointerInput] {
        guard !pressedButtons.isEmpty else {
            accumulator.reset()
            return []
        }
        let pixel = lastPixel
        let events = PointerButton.allCases
            .filter { pressedButtons.contains($0) }
            .map { PointerInput.button($0, .up, at: pixel) }
        pressedButtons = []
        accumulator.reset()
        return events
    }

    /// Forgets where the pointer was without emitting anything. Used when the
    /// desktop is replaced, since the remembered pixel was measured against a
    /// surface that no longer exists.
    public mutating func forgetPosition() {
        hasLastPixel = false
        lastPixel = PixelPoint(x: 0, y: 0)
    }
}
