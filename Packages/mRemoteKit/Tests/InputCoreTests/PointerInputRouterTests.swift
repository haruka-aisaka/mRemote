import XCTest
import SessionCore
@testable import InputCore

final class PointerInputRouterTests: XCTestCase {
    /// A 400x200 desktop drawn 1:1 inside a 1000x500 viewport, so the content
    /// starts at (300, 150) and a local point maps to a desktop pixel by
    /// subtracting that origin.
    private func router(scroll: ScrollDirection = .normal) -> PointerInputRouter {
        PointerInputRouter(
            transform: ViewportTransform(
                desktopWidth: 400,
                desktopHeight: 200,
                viewport: ViewportSize(width: 1_000, height: 500),
                scaleMode: .oneToOne
            ),
            scrollDirection: scroll
        )
    }

    private func local(_ x: Double, _ y: Double) -> ViewportPoint {
        ViewportPoint(x: 300 + x, y: 150 + y)
    }

    // MARK: - Movement

    func testAMoveIsReportedInDesktopPixels() {
        var router = router()
        XCTAssertEqual(router.moved(to: local(10, 20)), [.move(PixelPoint(x: 10, y: 20))])
        XCTAssertEqual(router.lastPixel, PixelPoint(x: 10, y: 20))
    }

    func testMovingWithinOnePixelSendsNothing() {
        // A trackpad reports far more positions than a desktop has pixels, and
        // the remote host learns nothing from being told the same one twice.
        var router = router()
        _ = router.moved(to: local(10, 20))
        XCTAssertEqual(router.moved(to: local(10.4, 20.4)), [])
        XCTAssertEqual(router.moved(to: local(11, 20)), [.move(PixelPoint(x: 11, y: 20))])
    }

    func testTheFirstMoveIsAlwaysSentEvenAtTheOrigin() {
        var router = router()
        XCTAssertEqual(router.moved(to: local(0, 0)), [.move(PixelPoint(x: 0, y: 0))])
    }

    func testAPointOutsideTheDesktopIsClampedRatherThanDropped() {
        // A drag that leaves the content has to keep sending the edge pixel,
        // or a selection stops growing the moment the pointer overshoots.
        var router = router()
        XCTAssertEqual(router.moved(to: local(-500, -500)), [.move(PixelPoint(x: 0, y: 0))])
        XCTAssertEqual(router.moved(to: local(5_000, 5_000)), [.move(PixelPoint(x: 399, y: 199))])
    }

    // MARK: - Buttons

    func testPressAndReleaseAreReportedAtTheCurrentPixel() {
        var router = router()
        _ = router.moved(to: local(30, 40))
        XCTAssertEqual(
            router.buttonsChanged(to: [.left]),
            [.button(.left, .down, at: PixelPoint(x: 30, y: 40))]
        )
        XCTAssertEqual(router.pressedButtons, [.left])
        XCTAssertEqual(
            router.buttonsChanged(to: []),
            [.button(.left, .up, at: PixelPoint(x: 30, y: 40))]
        )
        XCTAssertTrue(router.pressedButtons.isEmpty)
    }

    func testAButtonChangeMovesFirstSoTheClickLandsWhereItWasMade() {
        var router = router()
        XCTAssertEqual(
            router.buttonsChanged(to: [.right], at: local(7, 8)),
            [
                .move(PixelPoint(x: 7, y: 8)),
                .button(.right, .down, at: PixelPoint(x: 7, y: 8)),
            ]
        )
    }

    func testAnUnchangedButtonSetProducesNothing() {
        var router = router()
        _ = router.buttonsChanged(to: [.left])
        XCTAssertEqual(router.buttonsChanged(to: [.left]), [])
    }

    func testSwappingButtonsReleasesBeforeItPresses() {
        // Both down at once on the server would read as a chord the user never
        // made.
        var router = router()
        _ = router.buttonsChanged(to: [.left])
        XCTAssertEqual(
            router.buttonsChanged(to: [.right]),
            [
                .button(.left, .up, at: PixelPoint(x: 0, y: 0)),
                .button(.right, .down, at: PixelPoint(x: 0, y: 0)),
            ]
        )
        XCTAssertEqual(router.pressedButtons, [.right])
    }

    func testAButtonReleasedWithoutBeingObservedIsStillReleased() {
        // The platform reports what is held now, not what changed, so a
        // release the app never saw still has to reach the server.
        var router = router()
        _ = router.buttonsChanged(to: [.left, .right])
        let events = router.buttonsChanged(to: [])
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.allSatisfy {
            if case .button(_, .up, _) = $0 { return true }
            return false
        })
    }

    // MARK: - Release on focus loss

    func testReleaseAllReleasesEveryHeldButton() {
        var router = router()
        _ = router.moved(to: local(50, 60))
        _ = router.buttonsChanged(to: [.left, .middle])
        XCTAssertEqual(
            Set(router.releaseAll()),
            [
                .button(.left, .up, at: PixelPoint(x: 50, y: 60)),
                .button(.middle, .up, at: PixelPoint(x: 50, y: 60)),
            ]
        )
        XCTAssertTrue(router.pressedButtons.isEmpty)
    }

    func testReleaseAllIsIdempotentAndSilentWhenNothingIsHeld() {
        var router = router()
        _ = router.buttonsChanged(to: [.left])
        XCTAssertEqual(router.releaseAll().count, 1)
        XCTAssertEqual(router.releaseAll(), [])
        XCTAssertEqual(router.releaseAll(), [])
    }

    func testReleaseAllDropsTheScrollRemainder() {
        var router = router()
        // Half a unit of scroll, retained but not yet emitted.
        _ = router.scrolled(horizontal: 0, vertical: 0.04)
        _ = router.releaseAll()
        // Without the reset this would tip over into a unit on its own.
        XCTAssertEqual(router.scrolled(horizontal: 0, vertical: 0.04), [])
    }

    // MARK: - Scrolling

    func testScrollingIsQuantisedIntoRotationUnits() {
        var router = router()
        XCTAssertEqual(
            router.scrolled(horizontal: 0, vertical: 10),
            [.scroll(horizontal: 0, vertical: 120)]
        )
    }

    func testAFingerMovingDownScrollsInThePositiveDirection() {
        // RDP encodes wheel-forward as positive, and on a natural-scrolling
        // trackpad fingers moving down is the same gesture.
        var router = router()
        guard case .scroll(_, let vertical)? = router
            .scrolled(horizontal: 0, vertical: 1).first else {
            return XCTFail("expected a scroll")
        }
        XCTAssertGreaterThan(vertical, 0)
    }

    func testReversedDirectionInvertsBothAxes() {
        var router = router(scroll: .reversed)
        XCTAssertEqual(
            router.scrolled(horizontal: 1, vertical: 10),
            [.scroll(horizontal: -12, vertical: -120)]
        )
    }

    func testASlowScrollAccumulatesInsteadOfBeingLost() {
        var router = router()
        // A twelfth of a unit per event is under the threshold on its own;
        // dropping it would make a slow scroll do nothing at all rather than
        // move slowly.
        let step = 1.0 / ScrollWheelAccumulator.unitsPerPoint / 12
        var emitted: [PointerInput] = []
        for _ in 0..<12 {
            emitted += router.scrolled(horizontal: 0, vertical: step)
        }
        XCTAssertEqual(emitted, [.scroll(horizontal: 0, vertical: 1)])
    }

    func testChangingDirectionDropsTheRemainderRatherThanNegatingIt() {
        var router = router()
        _ = router.scrolled(horizontal: 0, vertical: 0.04)
        router.setScrollDirection(.reversed)
        XCTAssertEqual(router.scrollDirection, .reversed)
        XCTAssertEqual(router.scrolled(horizontal: 0, vertical: 0.04), [])
    }

    func testANonFiniteScrollIsIgnoredRatherThanPoisoningTheRemainder() {
        var router = router()
        XCTAssertEqual(router.scrolled(horizontal: .nan, vertical: .infinity), [])
        XCTAssertEqual(
            router.scrolled(horizontal: 0, vertical: 10),
            [.scroll(horizontal: 0, vertical: 120)]
        )
    }

    // MARK: - Geometry changes

    func testAResizedDesktopForgetsThePreviousPixel() {
        var router = router()
        _ = router.moved(to: local(10, 20))
        router.transform = router.transform.with(desktopWidth: 1_920, desktopHeight: 1_080)
        router.forgetPosition()
        // The same local point is a different desktop pixel now, and the first
        // move after the change must be sent even if it happened to match.
        XCTAssertFalse(router.moved(to: local(10, 20)).isEmpty)
    }

    func testZoomingChangesWhereALocalPointLands() {
        var router = router()
        _ = router.moved(to: local(100, 50))
        router.transform = router.transform.with(zoom: 2)
        router.forgetPosition()
        let zoomed = router.moved(to: local(100, 50))
        XCTAssertNotEqual(zoomed, [.move(PixelPoint(x: 100, y: 50))])
    }
}

final class ScrollWheelAccumulatorTests: XCTestCase {
    func testOneDetentOfScrollingIsOneHundredAndTwentyUnits() {
        var accumulator = ScrollWheelAccumulator()
        let delta = accumulator.consume(horizontal: 0, vertical: 10)
        XCTAssertEqual(delta.vertical, 120)
        XCTAssertEqual(delta.horizontal, 0)
    }

    func testAxesAccumulateIndependently() {
        var accumulator = ScrollWheelAccumulator()
        // Enough vertical for a unit, not enough horizontal.
        _ = accumulator.consume(horizontal: 0.04, vertical: 0)
        let delta = accumulator.consume(horizontal: 0, vertical: 1)
        XCTAssertEqual(delta.horizontal, 0)
        XCTAssertEqual(delta.vertical, 12)
    }

    func testNegativeAndPositiveFractionsCrossAtTheSameMagnitude() {
        var up = ScrollWheelAccumulator()
        var down = ScrollWheelAccumulator()
        let step = 1.0 / ScrollWheelAccumulator.unitsPerPoint / 2
        XCTAssertEqual(up.consume(horizontal: 0, vertical: step).vertical, 0)
        XCTAssertEqual(down.consume(horizontal: 0, vertical: -step).vertical, 0)
        XCTAssertEqual(up.consume(horizontal: 0, vertical: step).vertical, 1)
        XCTAssertEqual(down.consume(horizontal: 0, vertical: -step).vertical, -1)
    }

    func testAnExtremeValueSaturatesWithoutRetainingAHugeRemainder() {
        var accumulator = ScrollWheelAccumulator()
        XCTAssertEqual(
            accumulator.consume(horizontal: 0, vertical: Double(Int32.max)).vertical,
            Int32.max
        )
        // The next ordinary scroll must not be drowned out by what was left.
        XCTAssertEqual(accumulator.consume(horizontal: 0, vertical: 10).vertical, 120)
    }
}
