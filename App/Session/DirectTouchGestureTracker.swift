import UIKit
import SessionCore

/// What absolute touches drive: the surface, which maps a point on screen to
/// a desktop pixel.
@MainActor
protocol DirectPointerControl: AnyObject {
    /// Puts the remote pointer under the finger.
    func movePointer(to point: CGPoint)
    /// The buttons held now, with the pointer moved to `point` first.
    func setTouchButtons(_ buttons: Set<PointerButton>, at point: CGPoint)
    func scrollRemote(dx: Double, dy: Double)
}

/// Turns touches on the desktop into pointer input at the place touched,
/// the way a touch screen on Windows behaves (docs/input-design.md
/// section 9):
///
/// - a tap clicks where the finger was; two taps close together in time and
///   place land on the same pixel, so they read as a double click;
/// - a finger held still is a right click;
/// - a finger moved drags with the left button, from where it went down;
/// - two fingers moving scroll where they are, and a two-finger tap is a
///   right click.
///
/// Pinch is not here: it zooms the local view, and when it begins UIKit
/// cancels these touches, which ends whatever was under way without a click.
@MainActor
final class DirectTouchGestureTracker {
    typealias Sample = TrackpadGestureTracker.Sample
    typealias Scheduler = TrackpadGestureTracker.Scheduler

    private let target: () -> (any DirectPointerControl)?
    private let schedule: Scheduler
    private let haptics = UIImpactFeedbackGenerator(style: .light)

    private var touches: [ObjectIdentifier: CGPoint] = [:]
    /// Where the first finger went down: a tap clicks there, not wherever
    /// the finger wandered within the tap's slop.
    private var origin: CGPoint = .zero
    private var maximumTouches = 0
    private var travel: CGFloat = 0
    private var startTime: TimeInterval = 0
    private var isDragging = false
    /// The pointer has been put under the fingers for this scroll.
    private var isScrolling = false
    /// The long press already clicked, so lifting the finger must not.
    private var isSpent = false
    private var cancelLongPress: (() -> Void)?
    private var lastTap: (point: CGPoint, time: TimeInterval)?

    private(set) var isEnabled = false

    static let tapTravel = TrackpadGestureTracker.tapTravel
    static let rightClickHold: TimeInterval = 0.5
    /// Windows' default double-click time is 500 ms; its distance is a few
    /// pixels, which a finger misses on a scaled desktop.
    static let doubleTapInterval: TimeInterval = 0.5
    static let doubleTapDistance: CGFloat = 24

    init(
        target: @escaping () -> (any DirectPointerControl)?,
        schedule: @escaping Scheduler = TrackpadGestureTracker.runLoopTimer
    ) {
        self.target = target
        self.schedule = schedule
    }

    var isTracking: Bool { !touches.isEmpty }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if !enabled { reset() }
    }

    /// Forgets the sequence, releasing a drag's button: it must not outlive
    /// the finger that held it.
    func reset() {
        disarmLongPress()
        if isDragging {
            isDragging = false
            target()?.setTouchButtons([], at: touches.values.first ?? origin)
        }
        touches = [:]
        isScrolling = false
        maximumTouches = 0
        travel = 0
        isSpent = false
    }

    // MARK: - UIKit touches

    func began(_ touch: UITouch, in view: UIView) {
        began(Self.sample(touch, in: view))
    }

    func moved(_ moved: [UITouch], in view: UIView) {
        self.moved(moved.map { Self.sample($0, in: view) })
    }

    func ended(_ touch: UITouch, in view: UIView, cancelled: Bool) {
        ended(Self.sample(touch, in: view), cancelled: cancelled)
    }

    private static func sample(_ touch: UITouch, in view: UIView) -> Sample {
        Sample(id: ObjectIdentifier(touch), location: touch.location(in: view), timestamp: touch.timestamp)
    }

    // MARK: - Gesture

    func began(_ sample: Sample) {
        if touches.isEmpty {
            reset()
            origin = sample.location
            startTime = sample.timestamp
        }
        touches[sample.id] = sample.location
        maximumTouches = max(maximumTouches, touches.count)
        disarmLongPress()
        if touches.count == 1 {
            cancelLongPress = schedule(Self.rightClickHold) { [weak self] in self?.longPress() }
        }
    }

    func moved(_ samples: [Sample]) {
        var sum = CGPoint.zero
        var count = 0
        for sample in samples {
            guard let previous = touches[sample.id] else { continue }
            sum.x += sample.location.x - previous.x
            sum.y += sample.location.y - previous.y
            touches[sample.id] = sample.location
            count += 1
        }
        guard count > 0 else { return }
        let delta = CGPoint(x: sum.x / CGFloat(count), y: sum.y / CGFloat(count))
        travel += hypot(delta.x, delta.y)
        if travel >= Self.tapTravel { disarmLongPress() }

        guard isEnabled, !isSpent, let target = target() else { return }
        if isDragging {
            if let point = samples.last(where: { touches[$0.id] != nil })?.location {
                target.movePointer(to: point)
            }
        } else if maximumTouches >= 2 {
            if touches.count >= 2 {
                // The wheel goes to the window under the pointer, which a
                // touch never moved: put it under the fingers first.
                if !isScrolling {
                    isScrolling = true
                    target.movePointer(to: origin)
                }
                target.scrollRemote(dx: Double(delta.x), dy: Double(delta.y))
            }
        } else if travel >= Self.tapTravel, let point = touches.values.first {
            // Pressed where the finger went down, so the drag picks up what
            // was under it rather than what it had slid onto.
            isDragging = true
            target.setTouchButtons([.left], at: origin)
            target.movePointer(to: point)
        }
    }

    func ended(_ sample: Sample, cancelled: Bool) {
        guard touches[sample.id] != nil else { return }
        touches[sample.id] = sample.location
        let isLast = touches.count == 1
        if isDragging, isLast {
            isDragging = false
            if isEnabled { target()?.setTouchButtons([], at: sample.location) }
        }
        touches.removeValue(forKey: sample.id)
        guard touches.isEmpty else { return }
        let wasTap = !cancelled && !isSpent && travel < Self.tapTravel
        if wasTap, isEnabled, let target = target() {
            haptics.impactOccurred()
            if maximumTouches >= 2 {
                click(.right, at: origin, on: target)
                lastTap = nil
            } else {
                click(.left, at: tapPoint(at: sample.timestamp), on: target)
            }
        } else {
            lastTap = nil
        }
        reset()
    }

    /// The second tap of a double tap clicks where the first one did.
    private func tapPoint(at time: TimeInterval) -> CGPoint {
        defer { lastTap = (origin, time) }
        guard let lastTap,
              time - lastTap.time <= Self.doubleTapInterval,
              hypot(origin.x - lastTap.point.x, origin.y - lastTap.point.y) <= Self.doubleTapDistance
        else { return origin }
        return lastTap.point
    }

    private func click(_ button: PointerButton, at point: CGPoint, on target: any DirectPointerControl) {
        target.setTouchButtons([button], at: point)
        target.setTouchButtons([], at: point)
    }

    private func disarmLongPress() {
        cancelLongPress?()
        cancelLongPress = nil
    }

    private func longPress() {
        cancelLongPress = nil
        guard isEnabled, touches.count == 1, travel < Self.tapTravel, !isDragging,
              let target = target() else { return }
        isSpent = true
        lastTap = nil
        haptics.impactOccurred(intensity: 1)
        click(.right, at: origin, on: target)
    }
}
