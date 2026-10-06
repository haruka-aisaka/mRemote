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
    private let target: () -> (any RemotePointerControl)?
    private let haptics = UIImpactFeedbackGenerator(style: .light)

    private var touches: [ObjectIdentifier: CGPoint] = [:]
    private var maximumTouches = 0
    private var travel: CGFloat = 0
    private var startTime: TimeInterval = 0
    private var lastTime: TimeInterval = 0
    private var isDragging = false
    private var longPressTimer: Timer?

    private(set) var isEnabled = false

    static let tapTravel: CGFloat = 8
    static let tapDuration: TimeInterval = 0.3
    static let dragHold: TimeInterval = 0.45

    init(target: @escaping () -> (any RemotePointerControl)?) {
        self.target = target
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
        longPressTimer?.invalidate()
        longPressTimer = nil
        if isDragging {
            isDragging = false
            target()?.setLaptopButton(.left, pressed: false)
        }
        touches = [:]
        maximumTouches = 0
        travel = 0
    }

    func began(_ touch: UITouch, in view: UIView) {
        if touches.isEmpty {
            reset()
            startTime = touch.timestamp
            lastTime = touch.timestamp
        }
        touches[ObjectIdentifier(touch)] = touch.location(in: view)
        maximumTouches = max(maximumTouches, touches.count)
        if touches.count == 1 {
            armLongPress()
        } else {
            longPressTimer?.invalidate()
            longPressTimer = nil
        }
    }

    func moved(_ moved: [UITouch], in view: UIView) {
        var sum = CGPoint.zero
        var count = 0
        var timestamp = lastTime
        for touch in moved {
            let id = ObjectIdentifier(touch)
            guard let previous = touches[id] else { continue }
            let location = touch.location(in: view)
            sum.x += location.x - previous.x
            sum.y += location.y - previous.y
            touches[id] = location
            count += 1
            timestamp = max(timestamp, touch.timestamp)
        }
        guard count > 0 else { return }
        let delta = CGPoint(x: sum.x / CGFloat(count), y: sum.y / CGFloat(count))
        travel += hypot(delta.x, delta.y)
        let elapsed = max(timestamp - lastTime, 1.0 / 240)
        lastTime = timestamp
        if travel >= Self.tapTravel, !isDragging {
            longPressTimer?.invalidate()
            longPressTimer = nil
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

    func ended(_ touch: UITouch, cancelled: Bool) {
        guard touches.removeValue(forKey: ObjectIdentifier(touch)) != nil else { return }
        guard touches.isEmpty else { return }
        let wasTap = !cancelled
            && !isDragging
            && travel < Self.tapTravel
            && touch.timestamp - startTime < Self.tapDuration
        if wasTap, isEnabled {
            haptics.impactOccurred()
            target()?.clickRemote(maximumTouches >= 2 ? .right : .left)
        }
        reset()
    }

    private func armLongPress() {
        longPressTimer?.invalidate()
        let timer = Timer(timeInterval: Self.dragHold, repeats: false) { _ in
            MainActor.assumeIsolated { [weak self] in self?.beginDrag() }
        }
        RunLoop.main.add(timer, forMode: .common)
        longPressTimer = timer
    }

    private func beginDrag() {
        longPressTimer = nil
        guard isEnabled, touches.count == 1, travel < Self.tapTravel, !isDragging else { return }
        isDragging = true
        haptics.impactOccurred(intensity: 1)
        target()?.setLaptopButton(.left, pressed: true)
    }
}
