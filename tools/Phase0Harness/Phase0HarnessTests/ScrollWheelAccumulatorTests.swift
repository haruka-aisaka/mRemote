import XCTest
#if SWIFT_PACKAGE
@testable import Phase0HarnessLogic
#else
@testable import Phase0Harness
#endif

final class ScrollWheelAccumulatorTests: XCTestCase {
    func testRetainsHorizontalAndVerticalFractionsIndependently() {
        var accumulator = ScrollWheelAccumulator()

        XCTAssertEqual(
            accumulator.consume(horizontal: 0.25, vertical: 0.75),
            QuantizedScrollDelta(horizontal: 0, vertical: 0)
        )
        XCTAssertEqual(
            accumulator.consume(horizontal: 0.75, vertical: 0),
            QuantizedScrollDelta(horizontal: 1, vertical: 0)
        )
        XCTAssertEqual(
            accumulator.consume(horizontal: 0, vertical: 0.25),
            QuantizedScrollDelta(horizontal: 0, vertical: 1)
        )
    }

    func testPositiveAndNegativeFractionsQuantizeSymmetrically() {
        var positive = ScrollWheelAccumulator()
        var negative = ScrollWheelAccumulator()
        let samples = [0.25, 0.25, 0.5, 1.75]

        let positiveOutput = samples.map {
            positive.consume(horizontal: $0, vertical: 0).horizontal
        }
        let negativeOutput = samples.map {
            negative.consume(horizontal: -$0, vertical: 0).horizontal
        }

        XCTAssertEqual(positiveOutput, [0, 0, 1, 1])
        XCTAssertEqual(negativeOutput, positiveOutput.map(-))
    }

    func testOppositeFractionsCancelWithoutDirectionalBias() {
        var accumulator = ScrollWheelAccumulator()

        XCTAssertTrue(accumulator.consume(horizontal: 0.75, vertical: -0.75).isZero)
        XCTAssertTrue(accumulator.consume(horizontal: -0.5, vertical: 0.5).isZero)
        XCTAssertTrue(accumulator.consume(horizontal: -0.25, vertical: 0.25).isZero)
        XCTAssertEqual(
            accumulator.consume(horizontal: -1, vertical: 1),
            QuantizedScrollDelta(horizontal: -1, vertical: 1)
        )
    }

    func testReversalAppliesOnceToBothAxes() {
        var accumulator = ScrollWheelAccumulator(direction: .reversed)

        XCTAssertEqual(
            accumulator.consume(horizontal: 1.25, vertical: -2.75),
            QuantizedScrollDelta(horizontal: -1, vertical: 2)
        )
        XCTAssertEqual(
            accumulator.consume(horizontal: 0.75, vertical: -0.25),
            QuantizedScrollDelta(horizontal: -1, vertical: 1)
        )
    }

    func testResetAndDirectionChangeDiscardOldResiduals() {
        var accumulator = ScrollWheelAccumulator()
        XCTAssertTrue(accumulator.consume(horizontal: 0.75, vertical: 0).isZero)

        accumulator.reset()
        XCTAssertTrue(accumulator.consume(horizontal: 0.25, vertical: 0).isZero)
        XCTAssertTrue(accumulator.setDirection(.reversed))
        XCTAssertTrue(accumulator.consume(horizontal: 0.75, vertical: 0).isZero)
        XCTAssertEqual(
            accumulator.consume(horizontal: 0.25, vertical: 0),
            QuantizedScrollDelta(horizontal: -1, vertical: 0)
        )
        XCTAssertFalse(accumulator.setDirection(.reversed))
    }

    func testNonFiniteAxisIsIgnoredWithoutDestroyingOtherResidual() {
        var accumulator = ScrollWheelAccumulator()

        XCTAssertTrue(accumulator.consume(horizontal: 0.75, vertical: 0.75).isZero)
        XCTAssertEqual(
            accumulator.consume(horizontal: .infinity, vertical: 0.25),
            QuantizedScrollDelta(horizontal: 0, vertical: 1)
        )
        XCTAssertEqual(
            accumulator.consume(horizontal: 0.25, vertical: .nan),
            QuantizedScrollDelta(horizontal: 1, vertical: 0)
        )
    }

    func testSaturationDoesNotPoisonLaterDeviceInput() {
        var accumulator = ScrollWheelAccumulator()

        XCTAssertEqual(
            accumulator.consume(
                horizontal: Double.greatestFiniteMagnitude,
                vertical: -Double.greatestFiniteMagnitude
            ),
            QuantizedScrollDelta(horizontal: .max, vertical: .min)
        )
        XCTAssertTrue(accumulator.consume(horizontal: 0.25, vertical: -0.25).isZero)
        XCTAssertEqual(
            accumulator.consume(horizontal: 0.75, vertical: -0.75),
            QuantizedScrollDelta(horizontal: 1, vertical: -1)
        )
    }
}
