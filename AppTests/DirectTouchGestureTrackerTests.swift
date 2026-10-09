import XCTest
import SessionCore
@testable import mRemote

/// Touching the desktop directly, driven by plain samples: what reaches the
/// host for each gesture, and where.
@MainActor
final class DirectTouchGestureTrackerTests: XCTestCase {
    private final class Recorder: DirectPointerControl {
        var events: [String] = []
        var scrolled = CGVector.zero

        func movePointer(to point: CGPoint) {
            events.append("move \(Int(point.x)),\(Int(point.y))")
        }
        func setTouchButtons(_ buttons: Set<PointerButton>, at point: CGPoint) {
            let names = buttons.map { "\($0)" }.sorted().joined(separator: "+")
            events.append("\(names.isEmpty ? "none" : names) \(Int(point.x)),\(Int(point.y))")
        }
        func scrollRemote(dx: Double, dy: Double) {
            scrolled.dx += dx
            scrolled.dy += dy
            if events.last != "scroll" { events.append("scroll") }
        }
    }

    private let recorder = Recorder()
    private let fingers = [NSObject(), NSObject()]
    private var pendingLongPress: (@MainActor () -> Void)?

    private func makeTracker() -> DirectTouchGestureTracker {
        let tracker = DirectTouchGestureTracker(
            target: { [recorder] in recorder },
            schedule: { [unowned self] _, action in
                pendingLongPress = action
                return { [unowned self] in pendingLongPress = nil }
            }
        )
        tracker.setEnabled(true)
        return tracker
    }

    private func sample(_ finger: Int, _ x: CGFloat, _ y: CGFloat, at time: TimeInterval) -> DirectTouchGestureTracker.Sample {
        .init(id: ObjectIdentifier(fingers[finger]), location: CGPoint(x: x, y: y), timestamp: time)
    }

    func testATapClicksWhereTheFingerWentDown() {
        let tracker = makeTracker()
        tracker.began(sample(0, 100, 200, at: 0))
        tracker.moved([sample(0, 103, 202, at: 0.05)])
        tracker.ended(sample(0, 103, 202, at: 0.1), cancelled: false)
        XCTAssertEqual(recorder.events, ["left 100,200", "none 100,200"])
    }

    func testASecondTapNearbyLandsOnTheFirstSoItIsADoubleClick() {
        let tracker = makeTracker()
        tracker.began(sample(0, 100, 200, at: 0))
        tracker.ended(sample(0, 100, 200, at: 0.08), cancelled: false)
        tracker.began(sample(0, 110, 205, at: 0.2))
        tracker.ended(sample(0, 110, 205, at: 0.28), cancelled: false)
        XCTAssertEqual(recorder.events, [
            "left 100,200", "none 100,200",
            "left 100,200", "none 100,200",
        ])
    }

    func testATapLaterOrFartherAwayIsItsOwnClick() {
        let tracker = makeTracker()
        tracker.began(sample(0, 100, 200, at: 0))
        tracker.ended(sample(0, 100, 200, at: 0.08), cancelled: false)
        tracker.began(sample(0, 300, 200, at: 0.2))
        tracker.ended(sample(0, 300, 200, at: 0.28), cancelled: false)
        tracker.began(sample(0, 302, 200, at: 1.5))
        tracker.ended(sample(0, 302, 200, at: 1.58), cancelled: false)
        XCTAssertEqual(recorder.events.filter { $0.hasPrefix("left") }, [
            "left 100,200", "left 300,200", "left 302,200",
        ])
    }

    func testHoldingStillIsARightClickAndLiftingAddsNothing() throws {
        let tracker = makeTracker()
        tracker.began(sample(0, 50, 60, at: 0))
        try XCTUnwrap(pendingLongPress)()
        tracker.moved([sample(0, 80, 60, at: 0.7)])
        tracker.ended(sample(0, 80, 60, at: 0.8), cancelled: false)
        XCTAssertEqual(recorder.events, ["right 50,60", "none 50,60"])
    }

    func testMovingDragsFromWhereTheFingerWentDown() {
        let tracker = makeTracker()
        tracker.began(sample(0, 100, 100, at: 0))
        tracker.moved([sample(0, 120, 100, at: 0.05)])
        tracker.moved([sample(0, 160, 130, at: 0.1)])
        tracker.ended(sample(0, 170, 140, at: 0.15), cancelled: false)
        XCTAssertEqual(recorder.events, [
            "left 100,100", "move 120,100", "move 160,130", "none 170,140",
        ])
        XCTAssertNil(pendingLongPress, "a drag is not a right click")
    }

    func testTwoFingersMovingScrollAndDoNotClick() {
        let tracker = makeTracker()
        tracker.began(sample(0, 100, 100, at: 0))
        tracker.began(sample(1, 140, 100, at: 0.01))
        for step in 1...4 {
            let y = 100 - CGFloat(step) * 10
            tracker.moved([sample(0, 100, y, at: Double(step) * 0.02), sample(1, 140, y, at: Double(step) * 0.02)])
        }
        tracker.ended(sample(0, 100, 60, at: 0.2), cancelled: false)
        tracker.ended(sample(1, 140, 60, at: 0.2), cancelled: false)
        XCTAssertEqual(recorder.events, ["move 100,100", "scroll"])
        XCTAssertEqual(recorder.scrolled.dy, -40, accuracy: 0.001)
    }

    func testATwoFingerTapIsARightClickAtTheFirstFinger() {
        let tracker = makeTracker()
        tracker.began(sample(0, 100, 100, at: 0))
        tracker.began(sample(1, 140, 100, at: 0.01))
        tracker.ended(sample(0, 100, 100, at: 0.1), cancelled: false)
        tracker.ended(sample(1, 140, 100, at: 0.11), cancelled: false)
        XCTAssertEqual(recorder.events, ["right 100,100", "none 100,100"])
    }

    func testAPinchTakingOverEndsADragWithoutAClick() {
        let tracker = makeTracker()
        tracker.began(sample(0, 100, 100, at: 0))
        tracker.moved([sample(0, 130, 100, at: 0.05)])
        tracker.ended(sample(0, 130, 100, at: 0.1), cancelled: true)
        XCTAssertEqual(recorder.events.last, "none 130,100", "the button is released")
        XCTAssertEqual(recorder.events.filter { $0.hasPrefix("left") }.count, 1)
    }

    func testDisablingMidDragReleasesTheButton() {
        let tracker = makeTracker()
        tracker.began(sample(0, 100, 100, at: 0))
        tracker.moved([sample(0, 130, 100, at: 0.05)])
        tracker.setEnabled(false)
        XCTAssertEqual(recorder.events.last, "none 130,100")
        XCTAssertFalse(tracker.isTracking)
    }

    func testNothingIsSentWhileDisabled() {
        let tracker = makeTracker()
        tracker.setEnabled(false)
        tracker.began(sample(0, 100, 100, at: 0))
        tracker.ended(sample(0, 100, 100, at: 0.1), cancelled: false)
        XCTAssertEqual(recorder.events, [])
    }
}
