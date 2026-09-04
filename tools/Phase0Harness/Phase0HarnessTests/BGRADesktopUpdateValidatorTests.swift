import CoreGraphics
import XCTest
#if SWIFT_PACKAGE
@testable import Phase0HarnessLogic
#else
@testable import Phase0Harness
#endif

final class BGRADesktopUpdateValidatorTests: XCTestCase {
    func testEmptyDirtyListMeansFullDesktopUpload() throws {
        let result = try BGRADesktopUpdateValidator.validate(
            width: 1920,
            height: 1080,
            bytesPerRow: 7680,
            pixelCount: 8_294_400,
            dirtyRectangles: []
        )

        XCTAssertEqual(result.requiredBytes, 8_294_400)
        XCTAssertEqual(result.rectangles, [
            ValidatedPixelRectangle(x: 0, y: 0, width: 1920, height: 1080),
        ])
    }

    func testNewTextureForcesFullSeedForPartialDirtyUpdate() throws {
        let result = try BGRADesktopUpdateValidator.validate(
            width: 100,
            height: 50,
            bytesPerRow: 400,
            pixelCount: 20_000,
            dirtyRectangles: [CGRect(x: 5, y: 6, width: 7, height: 8)]
        )

        XCTAssertEqual(result.rectanglesForTexture(requiresFullSeed: false), [
            ValidatedPixelRectangle(x: 5, y: 6, width: 7, height: 8),
        ])
        XCTAssertEqual(result.rectanglesForTexture(requiresFullSeed: true), [
            ValidatedPixelRectangle(x: 0, y: 0, width: 100, height: 50),
        ])
    }

    func testWidthTimesFourOverflowIsRejectedWithoutTrapping() {
        XCTAssertThrowsError(try BGRADesktopUpdateValidator.validate(
            width: .max,
            height: 1,
            bytesPerRow: .max,
            pixelCount: .max,
            dirtyRectangles: []
        )) { error in
            XCTAssertEqual(error as? BGRADesktopUpdateError, .arithmeticOverflow)
        }
    }

    func testStrideTimesHeightOverflowIsRejectedWithoutTrapping() {
        XCTAssertThrowsError(try BGRADesktopUpdateValidator.validate(
            width: 1,
            height: 2,
            bytesPerRow: .max,
            pixelCount: .max,
            dirtyRectangles: []
        )) { error in
            XCTAssertEqual(error as? BGRADesktopUpdateError, .arithmeticOverflow)
        }
    }

    func testFiniteCGRectOutsideIntRangeIsRejectedWithoutTrapping() {
        let rectangle = CGRect(
            x: CGFloat.greatestFiniteMagnitude,
            y: 0,
            width: 1,
            height: 1
        )
        XCTAssertThrowsError(try BGRADesktopUpdateValidator.validate(
            width: 100,
            height: 100,
            bytesPerRow: 400,
            pixelCount: 40_000,
            dirtyRectangles: [rectangle]
        )) { error in
            XCTAssertEqual(
                error as? BGRADesktopUpdateError,
                .invalidDirtyRectangle(rectangle)
            )
        }
    }

    func testFractionalDirtyRectangleRoundsOutward() throws {
        let result = try BGRADesktopUpdateValidator.validate(
            width: 20,
            height: 20,
            bytesPerRow: 80,
            pixelCount: 1_600,
            dirtyRectangles: [CGRect(x: 0.25, y: 0.75, width: 3.25, height: 4)]
        )

        XCTAssertEqual(result.rectangles, [
            ValidatedPixelRectangle(x: 0, y: 0, width: 4, height: 5),
        ])
    }

    func testLatestFrameReplacementPreservesPendingPartialDamage() {
        let pending = damage(
            dirty: [CGRect(x: 5, y: 6, width: 10, height: 12)]
        )
        let newest = damage(
            dirty: [CGRect(x: 30, y: 25, width: 8, height: 9)]
        )

        XCTAssertEqual(
            LatestFrameDamageCoalescer.coalescedDamage(
                replacing: pending,
                with: newest
            ),
            [CGRect(x: 5, y: 6, width: 33, height: 28)]
        )
    }

    func testRepeatedReplacementKeepsPreviouslyCoalescedDamage() {
        let first = damage(dirty: [CGRect(x: 2, y: 3, width: 4, height: 5)])
        let second = damage(dirty: [CGRect(x: 20, y: 10, width: 3, height: 4)])
        let firstMerge = damage(
            dirty: LatestFrameDamageCoalescer.coalescedDamage(
                replacing: first,
                with: second
            )
        )
        let third = damage(dirty: [CGRect(x: 60, y: 40, width: 5, height: 6)])

        XCTAssertEqual(
            LatestFrameDamageCoalescer.coalescedDamage(
                replacing: firstMerge,
                with: third
            ),
            [CGRect(x: 2, y: 3, width: 63, height: 43)]
        )
    }

    func testSurfaceChangeForcesFullDamage() {
        let pending = damage(
            surfaceGeneration: 1,
            dirty: [CGRect(x: 1, y: 1, width: 2, height: 2)]
        )
        let newest = damage(
            surfaceGeneration: 2,
            dirty: [CGRect(x: 10, y: 10, width: 2, height: 2)]
        )

        XCTAssertEqual(
            LatestFrameDamageCoalescer.coalescedDamage(
                replacing: pending,
                with: newest
            ),
            []
        )
    }

    private func damage(
        surfaceGeneration: UInt64 = 1,
        dirty: [CGRect]
    ) -> FrameDamageEnvelope {
        FrameDamageEnvelope(
            generation: 7,
            surfaceGeneration: surfaceGeneration,
            width: 100,
            height: 50,
            bytesPerRow: 400,
            dirtyRectangles: dirty
        )
    }
}
