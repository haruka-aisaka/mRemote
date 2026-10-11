import XCTest
import SessionCore
@testable import mRemote

/// The trackpad's gestures, driven by plain samples: the two-finger ones in
/// particular cannot be produced by XCUITest on the iPhone Duo Simulator.
@MainActor
final class TrackpadGestureTrackerTests: XCTestCase {
    private final class Recorder: RemotePointerControl {
        var events: [String] = []
        var moved = CGVector.zero
        var scrolled = CGVector.zero

        func moveRemotePointer(dx: Double, dy: Double, speed: Double) {
            moved.dx += dx
            moved.dy += dy
            if events.last != "move" { events.append("move") }
        }
        func clickRemote(_ button: PointerButton) { events.append("click \(button)") }
        func setLaptopButton(_ button: PointerButton, pressed: Bool) {
            events.append("\(button) \(pressed ? "down" : "up")")
        }
        func scrollRemote(dx: Double, dy: Double) {
            scrolled.dx += dx
            scrolled.dy += dy
            if events.last != "scroll" { events.append("scroll") }
        }

        var macGestures = TrackpadMacGestures.none
        var gestures: [MacGestureInput] = []
        var phasedScrolls: [MacGesturePhase] = []
        var shortcuts: [SwipeDirection] = []

        func scrollRemote(dx: Double, dy: Double, phase: MacGesturePhase) {
            scrolled.dx += dx
            scrolled.dy += dy
            phasedScrolls.append(phase)
        }
        func sendMacGesture(_ input: MacGestureInput) {
            gestures.append(input)
            if events.last != "gesture" { events.append("gesture") }
        }
        func sendSwipeShortcut(_ direction: SwipeDirection) {
            shortcuts.append(direction)
            events.append("shortcut")
        }
    }

    private let recorder = Recorder()
    /// Stand-ins for UITouch identity; kept alive for the test's length.
    private let fingers = [NSObject(), NSObject(), NSObject()]
    private var pendingLongPress: (@MainActor () -> Void)?
    /// A tap's click, held back for a second touch.
    private var pendingClick: (@MainActor () -> Void)?

    private func makeTracker() -> TrackpadGestureTracker {
        let tracker = TrackpadGestureTracker(
            target: { [recorder] in recorder },
            schedule: { [unowned self] delay, action in
                if delay == TrackpadGestureTracker.doubleTapInterval {
                    pendingClick = action
                    return { [unowned self] in pendingClick = nil }
                }
                pendingLongPress = action
                return { [unowned self] in pendingLongPress = nil }
            }
        )
        tracker.setEnabled(true)
        return tracker
    }

    private func sample(_ finger: Int, _ x: CGFloat, _ y: CGFloat, at time: TimeInterval) -> TrackpadGestureTracker.Sample {
        .init(id: ObjectIdentifier(fingers[finger]), location: CGPoint(x: x, y: y), timestamp: time)
    }

    private func id(_ finger: Int) -> ObjectIdentifier { ObjectIdentifier(fingers[finger]) }

    func testOneFingerTapIsALeftClick() {
        let tracker = makeTracker()
        tracker.began(sample(0, 100, 100, at: 0))
        tracker.ended(id: id(0), at: 0.1, cancelled: false)
        XCTAssertEqual(recorder.events, [], "held back for a second touch")
        pendingClick?()
        XCTAssertEqual(recorder.events, ["click left"])
    }

    func testTwoTapsAreADoubleClick() {
        let tracker = makeTracker()
        tracker.began(sample(0, 100, 100, at: 0))
        tracker.ended(id: id(0), at: 0.1, cancelled: false)
        tracker.began(sample(0, 102, 101, at: 0.2))
        XCTAssertNil(pendingClick)
        tracker.ended(id: id(0), at: 0.3, cancelled: false)
        XCTAssertEqual(recorder.events, ["click left", "click left"])
        XCTAssertNil(pendingClick)
    }

    func testATapThenATouchMovedDragsWithoutAClick() {
        let tracker = makeTracker()
        tracker.began(sample(0, 100, 100, at: 0))
        tracker.ended(id: id(0), at: 0.1, cancelled: false)
        tracker.began(sample(0, 100, 100, at: 0.2))
        tracker.moved([sample(0, 112, 100, at: 0.25)])
        tracker.moved([sample(0, 160, 100, at: 0.3)])
        tracker.ended(id: id(0), at: 0.5, cancelled: false)
        XCTAssertEqual(recorder.events, ["left down", "move", "left up"],
                       "a press alone: an earlier click would make it a double click")
        XCTAssertNil(pendingClick)
    }

    func testATapThenTwoFingersIsAClickAndAScroll() {
        let tracker = makeTracker()
        tracker.began(sample(0, 100, 100, at: 0))
        tracker.ended(id: id(0), at: 0.1, cancelled: false)
        tracker.began(sample(0, 100, 100, at: 0.2))
        tracker.began(sample(1, 140, 100, at: 0.2))
        tracker.moved([sample(0, 100, 80, at: 0.25), sample(1, 140, 80, at: 0.25)])
        tracker.ended(id: id(0), at: 0.4, cancelled: false)
        tracker.ended(id: id(1), at: 0.4, cancelled: false)
        XCTAssertEqual(recorder.events, ["click left", "scroll"])
    }

    func testATapThenASlowTouchStillClicks() {
        let tracker = makeTracker()
        tracker.began(sample(0, 100, 100, at: 0))
        tracker.ended(id: id(0), at: 0.1, cancelled: false)
        tracker.began(sample(0, 100, 100, at: 0.2))
        tracker.ended(id: id(0), at: 0.2 + TrackpadGestureTracker.tapDuration + 0.05, cancelled: false)
        XCTAssertEqual(recorder.events, ["click left"])
    }

    func testTwoFingerTapIsARightClick() {
        let tracker = makeTracker()
        tracker.began(sample(0, 100, 100, at: 0))
        tracker.began(sample(1, 140, 100, at: 0.01))
        tracker.ended(id: id(0), at: 0.1, cancelled: false)
        tracker.ended(id: id(1), at: 0.11, cancelled: false)
        XCTAssertEqual(recorder.events, ["click right"])
    }

    func testTwoFingersMovingTogetherScrollAndDoNotMoveThePointer() {
        let tracker = makeTracker()
        tracker.began(sample(0, 100, 100, at: 0))
        tracker.began(sample(1, 140, 100, at: 0))
        for step in 1...5 {
            let y = 100 - CGFloat(step) * 10
            let time = Double(step) * 0.016
            tracker.moved([sample(0, 100, y, at: time), sample(1, 140, y, at: time)])
        }
        tracker.ended(id: id(0), at: 0.2, cancelled: false)
        tracker.ended(id: id(1), at: 0.2, cancelled: false)
        XCTAssertEqual(recorder.events, ["scroll"], "a scroll is not also a click")
        XCTAssertEqual(recorder.scrolled.dy, -50, accuracy: 0.001, "the fingers' own travel")
        XCTAssertEqual(recorder.moved, .zero)
    }

    func testOneFingerMovingMovesThePointerAndIsNoClick() {
        let tracker = makeTracker()
        tracker.began(sample(0, 100, 100, at: 0))
        tracker.moved([sample(0, 130, 120, at: 0.05)])
        tracker.ended(id: id(0), at: 0.1, cancelled: false)
        XCTAssertEqual(recorder.events, ["move"])
        XCTAssertEqual(recorder.moved.dx, 30, accuracy: 0.001)
    }

    func testHoldingStillThenMovingDragsWithTheLeftButton() {
        let tracker = makeTracker()
        tracker.began(sample(0, 100, 100, at: 0))
        XCTAssertNotNil(pendingLongPress, "a single finger arms the hold")
        pendingLongPress?()
        tracker.moved([sample(0, 160, 100, at: 0.6)])
        tracker.ended(id: id(0), at: 0.7, cancelled: false)
        XCTAssertEqual(recorder.events, ["left down", "move", "left up"])
    }

    func testASecondFingerOrTravelDisarmsTheHold() {
        let tracker = makeTracker()
        tracker.began(sample(0, 100, 100, at: 0))
        tracker.began(sample(1, 140, 100, at: 0.02))
        XCTAssertNil(pendingLongPress)
        tracker.ended(id: id(0), at: 0.5, cancelled: true)
        tracker.ended(id: id(1), at: 0.5, cancelled: true)

        tracker.began(sample(0, 100, 100, at: 1))
        tracker.moved([sample(0, 120, 100, at: 1.05)])
        XCTAssertNil(pendingLongPress, "moving past the tap distance is not a hold")
    }

    func testAClosedGateSendsNothingAndReleasesADrag() {
        let tracker = makeTracker()
        tracker.began(sample(0, 100, 100, at: 0))
        pendingLongPress?()
        tracker.setEnabled(false)
        XCTAssertEqual(recorder.events, ["left down", "left up"], "the button does not outlive the gate")
        tracker.began(sample(0, 100, 100, at: 1))
        tracker.ended(id: id(0), at: 1.1, cancelled: false)
        pendingClick?()
        XCTAssertEqual(recorder.events.count, 2)
    }

    // MARK: - A Mac host's gestures

    private static let mac = TrackpadMacGestures(preciseScroll: true, pinch: true, swipes: .shortcuts)

    /// Two fingers moving apart: a magnify, ended when they lift, and no
    /// right click although they hardly travelled together.
    func testTwoFingersSpreadingMagnifyOnAMac() {
        recorder.macGestures = Self.mac
        let tracker = makeTracker()
        tracker.began(sample(0, 100, 100, at: 0))
        tracker.began(sample(1, 140, 100, at: 0))
        for step in 1...4 {
            let spread = CGFloat(step) * 10
            tracker.moved([sample(0, 100 - spread, 100, at: Double(step) * 0.016),
                           sample(1, 140 + spread, 100, at: Double(step) * 0.016)])
        }
        tracker.ended(id: id(0), at: 0.1, cancelled: false)
        tracker.ended(id: id(1), at: 0.1, cancelled: false)
        pendingClick?()
        let magnify = recorder.gestures.filter { $0.kind == .magnify }
        XCTAssertEqual(magnify.first?.phase, .began)
        XCTAssertEqual(magnify.last?.phase, .ended)
        let total = magnify.reduce(1.0) { $0 * (1 + $1.value) }
        XCTAssertEqual(total, 120.0 / 40.0, accuracy: 0.01, "the span went from 40 to 120")
        XCTAssertEqual(recorder.events, ["gesture"], "a pinch is no click")
    }

    /// Turning the pair clockwise on screen is a negative (clockwise) rotation.
    func testTwoFingersTurningRotate() {
        recorder.macGestures = Self.mac
        let tracker = makeTracker()
        tracker.began(sample(0, 100, 100, at: 0))
        tracker.began(sample(1, 200, 100, at: 0))
        // The second finger swings down (clockwise on screen) about the first.
        tracker.moved([sample(1, 200, 130, at: 0.05)])
        tracker.ended(id: id(1), at: 0.1, cancelled: false)
        tracker.ended(id: id(0), at: 0.1, cancelled: false)
        let rotation = recorder.gestures.filter { $0.kind == .rotate }.reduce(0) { $0 + $1.value }
        XCTAssertLessThan(rotation, -10)
    }

    /// Without the Mac's gestures, two fingers spreading are still a scroll.
    func testWithoutAMacTwoFingersStillScroll() {
        let tracker = makeTracker()
        tracker.began(sample(0, 100, 100, at: 0))
        tracker.began(sample(1, 140, 100, at: 0))
        tracker.moved([sample(0, 90, 120, at: 0.016), sample(1, 150, 120, at: 0.016)])
        tracker.ended(id: id(0), at: 0.1, cancelled: false)
        tracker.ended(id: id(1), at: 0.1, cancelled: false)
        XCTAssertEqual(recorder.events, ["scroll"])
        XCTAssertTrue(recorder.gestures.isEmpty)
    }

    /// On a Mac, two fingers scrolling carry their phases, ended on lift.
    func testAMacScrollHasPhases() {
        recorder.macGestures = Self.mac
        let tracker = makeTracker()
        tracker.began(sample(0, 100, 100, at: 0))
        tracker.began(sample(1, 140, 100, at: 0))
        for step in 1...3 {
            let y = 100 - CGFloat(step) * 10
            tracker.moved([sample(0, 100, y, at: Double(step) * 0.016), sample(1, 140, y, at: Double(step) * 0.016)])
        }
        tracker.ended(id: id(0), at: 0.1, cancelled: false)
        tracker.ended(id: id(1), at: 0.1, cancelled: false)
        XCTAssertEqual(recorder.phasedScrolls.first, .began)
        XCTAssertEqual(recorder.phasedScrolls.last, .ended)
        XCTAssertEqual(recorder.scrolled.dy, -30, accuracy: 0.001)
    }

    /// Two two-finger taps are smart zoom; the first one's right click never
    /// comes. One alone is still a right click, a moment later.
    func testTwoTwoFingerTapsAreSmartZoom() {
        recorder.macGestures = Self.mac
        let tracker = makeTracker()
        tracker.began(sample(0, 100, 100, at: 0))
        tracker.began(sample(1, 140, 100, at: 0))
        tracker.ended(id: id(0), at: 0.08, cancelled: false)
        tracker.ended(id: id(1), at: 0.08, cancelled: false)
        XCTAssertNotNil(pendingLongPress, "the right click waits")
        XCTAssertEqual(recorder.events, [])
        tracker.began(sample(0, 100, 100, at: 0.2))
        tracker.began(sample(1, 140, 100, at: 0.2))
        tracker.ended(id: id(0), at: 0.28, cancelled: false)
        tracker.ended(id: id(1), at: 0.28, cancelled: false)
        XCTAssertEqual(recorder.gestures.map(\.kind), [.smartZoom])
        XCTAssertFalse(recorder.events.contains("click right"))

        tracker.began(sample(0, 100, 100, at: 2))
        tracker.began(sample(1, 140, 100, at: 2))
        tracker.ended(id: id(0), at: 2.08, cancelled: false)
        tracker.ended(id: id(1), at: 2.08, cancelled: false)
        pendingLongPress?()
        XCTAssertEqual(recorder.events.last, "click right")
    }

    private func threeFingerSwipe(_ tracker: TrackpadGestureTracker, dx: CGFloat, dy: CGFloat, steps: Int = 6) {
        tracker.began(sample(0, 100, 150, at: 0))
        tracker.began(sample(1, 140, 150, at: 0))
        tracker.began(sample(2, 180, 150, at: 0))
        for step in 1...steps {
            let f = CGFloat(step) / CGFloat(steps)
            let t = Double(step) * 0.016
            tracker.moved([sample(0, 100 + dx * f, 150 + dy * f, at: t),
                           sample(1, 140 + dx * f, 150 + dy * f, at: t),
                           sample(2, 180 + dx * f, 150 + dy * f, at: t)])
        }
        for finger in 0..<3 { tracker.ended(id: id(finger), at: 0.2, cancelled: false) }
    }

    /// Three fingers up: Mission Control's shortcut, once.
    func testThreeFingersUpSendTheMissionControlShortcut() {
        recorder.macGestures = Self.mac
        let tracker = makeTracker()
        threeFingerSwipe(tracker, dx: 5, dy: -120)
        XCTAssertEqual(recorder.shortcuts, [.up])
        XCTAssertEqual(recorder.events, ["shortcut"], "neither a scroll nor a click")
    }

    /// Three fingers left bring in the Space to the right; a short swipe
    /// sends nothing.
    func testThreeFingersLeftSwitchSpacesAndAShortSwipeDoesNot() {
        recorder.macGestures = Self.mac
        let tracker = makeTracker()
        threeFingerSwipe(tracker, dx: -100, dy: 0)
        XCTAssertEqual(recorder.shortcuts, [.left])
        XCTAssertEqual(SwipeDirection.left.macShortcut.label, "⌃→")
        threeFingerSwipe(tracker, dx: 30, dy: 0)
        XCTAssertEqual(recorder.shortcuts, [.left])
    }

    /// Following the fingers: the Dock's swipe, its progress growing as they
    /// go up, ended (not called off) as they lift still going.
    func testThreeFingersFollowedAreADockSwipe() {
        recorder.macGestures = TrackpadMacGestures(preciseScroll: true, pinch: true, swipes: .followFingers)
        let tracker = makeTracker()
        tracker.padSize = CGSize(width: 400, height: 200)
        threeFingerSwipe(tracker, dx: 0, dy: -140)
        let dock = recorder.gestures.filter { $0.kind == .dockVertical }
        XCTAssertEqual(dock.first?.phase, .began)
        XCTAssertEqual(dock.last?.phase, .ended)
        XCTAssertEqual(dock.last?.value ?? 0, 1.0, accuracy: 0.01, "140 of 200 x 0.7 is the whole way")
        XCTAssertGreaterThan(dock.last?.velocity ?? 0, 0)
        XCTAssertTrue(recorder.shortcuts.isEmpty)
    }

    /// A Dock swipe let go short of halfway goes back unless flicked on:
    /// the Dock would complete any swipe that ends, so it is called off.
    func testShortDockSwipeGoesBackUnlessFlicked() {
        XCTAssertTrue(TrackpadGestureTracker.swipeCompletes(progress: 0.6, velocity: 0))
        XCTAssertTrue(TrackpadGestureTracker.swipeCompletes(progress: -0.6, velocity: 0))
        XCTAssertFalse(TrackpadGestureTracker.swipeCompletes(progress: 0.3, velocity: 0.2))
        XCTAssertTrue(TrackpadGestureTracker.swipeCompletes(progress: 0.2, velocity: 2))
        XCTAssertTrue(TrackpadGestureTracker.swipeCompletes(progress: -0.2, velocity: -2))
        XCTAssertFalse(TrackpadGestureTracker.swipeCompletes(progress: 0.3, velocity: -2))
        XCTAssertFalse(TrackpadGestureTracker.swipeCompletes(progress: 0.01, velocity: 3))
    }

    /// With swipes off, three fingers scroll as before.
    func testThreeFingersScrollWhenSwipesAreOff() {
        recorder.macGestures = TrackpadMacGestures(preciseScroll: false, pinch: true, swipes: .off)
        let tracker = makeTracker()
        threeFingerSwipe(tracker, dx: 0, dy: -120)
        XCTAssertEqual(recorder.events, ["scroll"])
    }

    func testASlowTouchIsNoTap() {
        let tracker = makeTracker()
        tracker.began(sample(0, 100, 100, at: 0))
        tracker.ended(id: id(0), at: TrackpadGestureTracker.tapDuration + 0.1, cancelled: false)
        XCTAssertEqual(recorder.events, [])
    }
}
