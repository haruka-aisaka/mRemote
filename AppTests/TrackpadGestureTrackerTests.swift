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
    }

    private let recorder = Recorder()
    /// Stand-ins for UITouch identity; kept alive for the test's length.
    private let fingers = [NSObject(), NSObject()]
    private var pendingLongPress: (@MainActor () -> Void)?

    private func makeTracker() -> TrackpadGestureTracker {
        let tracker = TrackpadGestureTracker(
            target: { [recorder] in recorder },
            schedule: { [unowned self] _, action in
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
        XCTAssertEqual(recorder.events.count, 2)
    }

    func testASlowTouchIsNoTap() {
        let tracker = makeTracker()
        tracker.began(sample(0, 100, 100, at: 0))
        tracker.ended(id: id(0), at: TrackpadGestureTracker.tapDuration + 0.1, cancelled: false)
        XCTAssertEqual(recorder.events, [])
    }
}
