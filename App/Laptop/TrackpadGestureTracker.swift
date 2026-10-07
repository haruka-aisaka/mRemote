import UIKit
import SessionCore

/// What a trackpad drives: the surface, which owns the remote pointer.
@MainActor
protocol RemotePointerControl: AnyObject {
    func moveRemotePointer(dx: Double, dy: Double, speed: Double)
    func clickRemote(_ button: PointerButton)
    func setLaptopButton(_ button: PointerButton, pressed: Bool)
    func scrollRemote(dx: Double, dy: Double)
}

/// Turns touches on any area used as a trackpad into remote pointer input:
/// the laptop deck's pad, or the desktop itself when the deck shows only
/// the keyboard.
///
/// - one finger moves the pointer, by travel rather than position;
/// - a tap is a left click, a two-finger tap a right click;
/// - two fingers moving scroll;
/// - a finger held still and then moved drags with the left button, which
///   is how a pad without buttons drags at all.
///
/// The owner forwards its touches; this keeps no reference to them beyond
/// their identity and last position.
@MainActor
final class TrackpadGestureTracker {
    /// One finger's position at a moment. UIKit's touches are reduced to
    /// this so the gesture logic can be exercised without UIKit's touches,
    /// which tests cannot create.
    struct Sample {
        let id: ObjectIdentifier
        let location: CGPoint
        let timestamp: TimeInterval
    }

    /// Arms the long-press that starts a drag; returns a cancel. A Timer in
    /// the app, replaced by tests that fire it themselves.
    typealias Scheduler = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void

    private let target: () -> (any RemotePointerControl)?
    private let schedule: Scheduler
    private let haptics = UIImpactFeedbackGenerator(style: .light)

    private var touches: [ObjectIdentifier: CGPoint] = [:]
    private var maximumTouches = 0
    private var travel: CGFloat = 0
    private var startTime: TimeInterval = 0
    private var lastTime: TimeInterval = 0
    private var isDragging = false
    private var cancelLongPress: (() -> Void)?

    private(set) var isEnabled = false

    static let tapTravel: CGFloat = 8
    static let tapDuration: TimeInterval = 0.3
    static let dragHold: TimeInterval = 0.45

    init(
        target: @escaping () -> (any RemotePointerControl)?,
        schedule: @escaping Scheduler = TrackpadGestureTracker.runLoopTimer
    ) {
        self.target = target
        self.schedule = schedule
    }

    static func runLoopTimer(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }

    var isTracking: Bool { !touches.isEmpty }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if !enabled { reset() }
    }

    /// Forgets the sequence, releasing a drag's button on the way: the
    /// button must not outlive the finger that held it.
    func reset() {
        disarmLongPress()
        if isDragging {
            isDragging = false
            target()?.setLaptopButton(.left, pressed: false)
        }
        touches = [:]
        maximumTouches = 0
        travel = 0
    }

    // MARK: - UIKit touches

    func began(_ touch: UITouch, in view: UIView) {
        began(Self.sample(touch, in: view))
    }

    func moved(_ moved: [UITouch], in view: UIView) {
        self.moved(moved.map { Self.sample($0, in: view) })
    }

    func ended(_ touch: UITouch, cancelled: Bool) {
        ended(id: ObjectIdentifier(touch), at: touch.timestamp, cancelled: cancelled)
    }

    private static func sample(_ touch: UITouch, in view: UIView) -> Sample {
        Sample(id: ObjectIdentifier(touch), location: touch.location(in: view), timestamp: touch.timestamp)
    }

    // MARK: - Gesture

    func began(_ sample: Sample) {
        if touches.isEmpty {
            reset()
            startTime = sample.timestamp
            lastTime = sample.timestamp
        }
        touches[sample.id] = sample.location
        maximumTouches = max(maximumTouches, touches.count)
        if touches.count == 1 {
            disarmLongPress()
            cancelLongPress = schedule(Self.dragHold) { [weak self] in self?.beginDrag() }
        } else {
            disarmLongPress()
        }
    }

    func moved(_ samples: [Sample]) {
        var sum = CGPoint.zero
        var count = 0
        var timestamp = lastTime
        for sample in samples {
            guard let previous = touches[sample.id] else { continue }
            sum.x += sample.location.x - previous.x
            sum.y += sample.location.y - previous.y
            touches[sample.id] = sample.location
            count += 1
            timestamp = max(timestamp, sample.timestamp)
        }
        guard count > 0 else { return }
        let delta = CGPoint(x: sum.x / CGFloat(count), y: sum.y / CGFloat(count))
        travel += hypot(delta.x, delta.y)
        let elapsed = max(timestamp - lastTime, 1.0 / 240)
        lastTime = timestamp
        if travel >= Self.tapTravel, !isDragging {
            disarmLongPress()
        }

        guard isEnabled, let target = target() else { return }
        if touches.count >= 2, !isDragging {
            // The deltas are the fingers' own, which is what
            // `ScrollWheelAccumulator` expects.
            target.scrollRemote(dx: Double(delta.x), dy: Double(delta.y))
        } else {
            let speed = Double(hypot(delta.x, delta.y)) / elapsed
            target.moveRemotePointer(dx: Double(delta.x), dy: Double(delta.y), speed: speed)
        }
    }

    func ended(id: ObjectIdentifier, at timestamp: TimeInterval, cancelled: Bool) {
        guard touches.removeValue(forKey: id) != nil else { return }
        guard touches.isEmpty else { return }
        let wasTap = !cancelled
            && !isDragging
            && travel < Self.tapTravel
            && timestamp - startTime < Self.tapDuration
        if wasTap, isEnabled {
            haptics.impactOccurred()
            target()?.clickRemote(maximumTouches >= 2 ? .right : .left)
        }
        reset()
    }

    private func disarmLongPress() {
        cancelLongPress?()
        cancelLongPress = nil
    }

    private func beginDrag() {
        cancelLongPress = nil
        guard isEnabled, touches.count == 1, travel < Self.tapTravel, !isDragging else { return }
        isDragging = true
        haptics.impactOccurred(intensity: 1)
        target()?.setLaptopButton(.left, pressed: true)
    }
}
