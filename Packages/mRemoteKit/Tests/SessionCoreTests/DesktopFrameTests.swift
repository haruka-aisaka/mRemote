import XCTest
@testable import SessionCore

final class DesktopFrameValidatorTests: XCTestCase {
    private func frame(
        width: Int = 4,
        height: Int = 4,
        bytesPerRow: Int? = nil,
        byteCount: Int? = nil,
        dirty: [PixelRect] = []
    ) -> DesktopFrame {
        let stride = bytesPerRow ?? width * 4
        return DesktopFrame(
            width: width,
            height: height,
            bytesPerRow: stride,
            pixels: Data(count: byteCount ?? stride * height),
            dirtyRectangles: dirty,
            generation: SessionGeneration(),
            surfaceGeneration: 1,
            frameID: 1
        )
    }

    func testAcceptsAFrameWhoseDamageIsInsideTheSurface() throws {
        let validated = try DesktopFrameValidator.validate(
            frame(dirty: [PixelRect(x: 1, y: 1, width: 2, height: 3)])
        )
        XCTAssertEqual(validated.requiredBytes, 64)
        XCTAssertEqual(validated.rectangles, [PixelRect(x: 1, y: 1, width: 2, height: 3)])
    }

    func testEmptyDamageMeansTheWholeSurface() throws {
        let validated = try DesktopFrameValidator.validate(frame())
        XCTAssertEqual(validated.rectangles, [PixelRect(x: 0, y: 0, width: 4, height: 4)])
    }

    func testRejectsARectangleThatLeavesTheSurface() {
        XCTAssertThrowsError(
            try DesktopFrameValidator.validate(
                frame(dirty: [PixelRect(x: 2, y: 0, width: 3, height: 1)])
            )
        ) { error in
            XCTAssertEqual(
                error as? DesktopFrameError,
                .invalidDirtyRectangle(PixelRect(x: 2, y: 0, width: 3, height: 1))
            )
        }
    }

    func testRejectsNegativeOrigins() {
        XCTAssertThrowsError(
            try DesktopFrameValidator.validate(
                frame(dirty: [PixelRect(x: -1, y: 0, width: 2, height: 1)])
            )
        )
    }

    func testRejectsAStrideNarrowerThanOneRow() {
        XCTAssertThrowsError(
            try DesktopFrameValidator.validate(frame(bytesPerRow: 15))
        ) { error in
            XCTAssertEqual(
                error as? DesktopFrameError,
                .invalidStride(bytesPerRow: 15, minimum: 16)
            )
        }
    }

    func testRejectsABufferShorterThanTheSurface() {
        XCTAssertThrowsError(
            try DesktopFrameValidator.validate(frame(byteCount: 63))
        ) { error in
            XCTAssertEqual(
                error as? DesktopFrameError,
                .truncatedBuffer(required: 64, actual: 63)
            )
        }
    }

    func testRejectsDimensionsBeyondTheBridgeLimit() {
        XCTAssertThrowsError(
            try DesktopFrameValidator.validate(
                width: 8_193,
                height: 4,
                bytesPerRow: 8_193 * 4,
                byteCount: 8_193 * 4 * 4,
                dirtyRectangles: []
            )
        )
        XCTAssertThrowsError(
            try DesktopFrameValidator.validate(
                width: 0,
                height: 4,
                bytesPerRow: 16,
                byteCount: 64,
                dirtyRectangles: []
            )
        )
    }

    func testRejectsMoreDirtyRectanglesThanTheBridgeWouldSend() {
        let many = (0..<513).map { _ in PixelRect(x: 0, y: 0, width: 1, height: 1) }
        XCTAssertThrowsError(try DesktopFrameValidator.validate(frame(dirty: many))) { error in
            XCTAssertEqual(
                error as? DesktopFrameError,
                .tooManyDirtyRectangles(count: 513, limit: 512)
            )
        }
    }

    func testAFrameLargerThanAddressableMemoryDoesNotTrap() {
        XCTAssertThrowsError(
            try DesktopFrameValidator.validate(
                width: 4,
                height: Int.max,
                bytesPerRow: 16,
                byteCount: 64,
                dirtyRectangles: []
            )
        )
    }

    func testAFullSeedUploadIgnoresPartialDamage() throws {
        let validated = try DesktopFrameValidator.validate(
            frame(dirty: [PixelRect(x: 1, y: 1, width: 1, height: 1)])
        )
        XCTAssertEqual(
            validated.rectanglesForUpload(requiresFullSeed: true),
            [PixelRect(x: 0, y: 0, width: 4, height: 4)]
        )
        XCTAssertEqual(
            validated.rectanglesForUpload(requiresFullSeed: false),
            [PixelRect(x: 1, y: 1, width: 1, height: 1)]
        )
    }
}

final class PixelRectTests: XCTestCase {
    func testUnionCoversBothRectangles() {
        let combined = PixelRect(x: 0, y: 0, width: 2, height: 2)
            .union(PixelRect(x: 8, y: 4, width: 2, height: 2))
        XCTAssertEqual(combined, PixelRect(x: 0, y: 0, width: 10, height: 6))
    }

    func testUnionWithAnEmptyRectangleKeepsTheOther() {
        let rectangle = PixelRect(x: 3, y: 3, width: 4, height: 4)
        XCTAssertEqual(rectangle.union(PixelRect(x: 0, y: 0, width: 0, height: 0)), rectangle)
        XCTAssertEqual(PixelRect(x: 0, y: 0, width: 0, height: 0).union(rectangle), rectangle)
    }
}
