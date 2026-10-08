import XCTest
@testable import SessionCore

final class ViewportTransformTests: XCTestCase {
    private let viewport = ViewportSize(width: 1_000, height: 500)

    private func transform(
        desktop: (width: Int, height: Int) = (1_920, 1_080),
        mode: InitialScale = .fit,
        zoom: Double = 1,
        pan: ViewportPoint = .zero,
        viewport: ViewportSize? = nil
    ) -> ViewportTransform {
        ViewportTransform(
            desktopWidth: desktop.width,
            desktopHeight: desktop.height,
            viewport: viewport ?? self.viewport,
            scaleMode: mode,
            zoom: zoom,
            pan: pan
        )
    }

    func testFitLetterboxesAndCentres() {
        let content = transform().contentRect
        // 1000/1920 > 500/1080, so height is the constraint.
        XCTAssertEqual(content.height, 500, accuracy: 0.001)
        XCTAssertEqual(content.width, 500 * 1_920 / 1_080, accuracy: 0.001)
        XCTAssertEqual(content.x, (1_000 - content.width) / 2, accuracy: 0.001)
        XCTAssertEqual(content.y, 0, accuracy: 0.001)
    }

    func testOneToOneDrawsAtNativePixels() {
        let content = transform(desktop: (400, 200), mode: .oneToOne).contentRect
        XCTAssertEqual(content.width, 400, accuracy: 0.001)
        XCTAssertEqual(content.height, 200, accuracy: 0.001)
        XCTAssertEqual(content.x, 300, accuracy: 0.001)
        XCTAssertEqual(content.y, 150, accuracy: 0.001)
    }

    func testCornersMapToTheFirstAndLastPixel() {
        let transform = transform(desktop: (400, 200), mode: .oneToOne)
        let content = transform.contentRect
        XCTAssertEqual(
            transform.remotePixel(fromLocal: ViewportPoint(x: content.x, y: content.y)),
            PixelPoint(x: 0, y: 0)
        )
        XCTAssertEqual(
            transform.remotePixel(
                fromLocal: ViewportPoint(x: content.maxX - 0.001, y: content.maxY - 0.001)
            ),
            PixelPoint(x: 399, y: 199)
        )
    }

    func testAPointOutsideTheContentIsClampedToTheEdge() {
        let transform = transform(desktop: (400, 200), mode: .oneToOne)
        XCTAssertEqual(
            transform.remotePixel(fromLocal: ViewportPoint(x: -500, y: -500)),
            PixelPoint(x: 0, y: 0)
        )
        XCTAssertEqual(
            transform.remotePixel(fromLocal: ViewportPoint(x: 5_000, y: 5_000)),
            PixelPoint(x: 399, y: 199)
        )
    }

    func testANonFinitePointDoesNotTrap() {
        let transform = transform()
        XCTAssertEqual(
            transform.remotePixel(fromLocal: ViewportPoint(x: .nan, y: .infinity)),
            PixelPoint(x: 0, y: 0)
        )
    }

    func testAFittedDesktopCannotBePanned() {
        let panned = transform(pan: ViewportPoint(x: 400, y: 400))
        XCTAssertEqual(panned.pan, .zero)
    }

    func testPanIsLimitedToTheOverhangOfAZoomedDesktop() {
        let zoomed = transform(zoom: 2)
        let limits = zoomed.panLimits
        // Fit scale doubles: the content is twice the viewport on the short
        // axis, so half of the overflow may be dragged into view.
        XCTAssertEqual(limits.y, 250, accuracy: 0.001)
        let panned = transform(zoom: 2, pan: ViewportPoint(x: 0, y: 10_000))
        XCTAssertEqual(panned.pan.y, 250, accuracy: 0.001)
    }

    func testAZoomedDesktopGrowsFromTheMiddleAndPansToEachEdgeButNoFurther() {
        let zoomed = transform(zoom: 2)
        // Twice the fitted 888.9x500: centred, then panned.
        XCTAssertEqual(zoomed.contentRect.y, -250, accuracy: 0.001)
        let top = transform(zoom: 2, pan: ViewportPoint(x: 0, y: 10_000)).contentRect
        XCTAssertEqual(top.y, 0, accuracy: 0.001, "the top edge, not the ground above it")
        let bottom = transform(zoom: 2, pan: ViewportPoint(x: 0, y: -10_000)).contentRect
        XCTAssertEqual(bottom.maxY, 500, accuracy: 0.001)
        let left = transform(zoom: 4, pan: ViewportPoint(x: 10_000, y: 0)).contentRect
        XCTAssertEqual(left.x, 0, accuracy: 0.001)
    }

    func testACoveredBottomLetsTheDesktopRiseAboveTheCover() {
        let covered = transform(pan: ViewportPoint(x: 0, y: -10_000)).with(zoom: 1)
        XCTAssertEqual(covered.pan, .zero, "nothing covers it yet")
        let keyboard = ViewportTransform(
            desktopWidth: 1_920, desktopHeight: 1_080, viewport: viewport,
            pan: ViewportPoint(x: 0, y: -10_000), occludedBottom: 200
        )
        XCTAssertEqual(keyboard.contentRect.maxY, 300, accuracy: 0.001)
        XCTAssertEqual(keyboard.visibleHeight, 300, accuracy: 0.001)
        let down = keyboard.with(pan: ViewportPoint(x: 0, y: 10_000))
        XCTAssertEqual(down.contentRect.y, 0, accuracy: 0.001, "still not past the top")
        let uncovered = ViewportTransform(
            desktopWidth: 1_920, desktopHeight: 1_080, viewport: viewport, pan: keyboard.pan
        )
        XCTAssertEqual(uncovered.pan, .zero, "falls back once the cover is gone")
    }

    func testZoomIsClampedToTheSupportedRange() {
        XCTAssertEqual(transform(zoom: 0.1).zoom, 1)
        XCTAssertEqual(transform(zoom: 100).zoom, 8)
        XCTAssertEqual(transform(zoom: .nan).zoom, 1)
    }

    func testAResolutionChangeDropsThePan() {
        let panned = transform(zoom: 4, pan: ViewportPoint(x: 100, y: 100))
        XCTAssertNotEqual(panned.pan, .zero)
        XCTAssertEqual(panned.with(desktopWidth: 1_280, desktopHeight: 720).pan, .zero)
    }

    func testAnEmptyViewportProducesNoContentInsteadOfDividingByZero() {
        let empty = transform(viewport: .zero)
        XCTAssertEqual(empty.contentRect, .zero)
        XCTAssertEqual(empty.remotePixel(fromLocal: ViewportPoint(x: 1, y: 1)), PixelPoint(x: 0, y: 0))
    }

    func testLocalPointRoundTripsThroughTheCentreOfAPixel() {
        let transform = transform(desktop: (400, 200), mode: .oneToOne, zoom: 2)
        for pixel in [PixelPoint(x: 0, y: 0), PixelPoint(x: 137, y: 42), PixelPoint(x: 399, y: 199)] {
            let local = transform.localPoint(fromRemote: pixel)
            XCTAssertEqual(transform.remotePixel(fromLocal: local), pixel)
        }
    }
}
