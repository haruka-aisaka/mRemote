import XCTest
@testable import SessionCore

final class LatestDesktopFrameStoreTests: XCTestCase {
    private func frame(
        id: UInt64,
        width: Int = 100,
        height: Int = 100,
        surfaceGeneration: UInt64 = 1,
        generation: SessionGeneration = SessionGeneration(),
        dirty: [PixelRect]
    ) -> DesktopFrame {
        DesktopFrame(
            width: width,
            height: height,
            bytesPerRow: width * 4,
            pixels: Data(count: width * height * 4),
            dirtyRectangles: dirty,
            generation: generation,
            surfaceGeneration: surfaceGeneration,
            frameID: id
        )
    }

    func testConsumeReturnsTheNewestFrame() {
        let store = LatestDesktopFrameStore()
        store.submit(frame(id: 1, dirty: [PixelRect(x: 0, y: 0, width: 1, height: 1)]))
        store.submit(frame(id: 2, dirty: [PixelRect(x: 0, y: 0, width: 1, height: 1)]))
        XCTAssertEqual(store.consume()?.frameID, 2)
        XCTAssertNil(store.consume())
    }

    func testSupersededDamageIsCarriedIntoTheSurvivingFrame() {
        let store = LatestDesktopFrameStore()
        store.submit(frame(id: 1, dirty: [PixelRect(x: 0, y: 0, width: 10, height: 10)]))
        store.submit(frame(id: 2, dirty: [PixelRect(x: 40, y: 40, width: 10, height: 10)]))
        let consumed = store.consume()
        XCTAssertEqual(consumed?.frameID, 2)
        // The renderer never drew frame 1, so frame 2 has to repaint both.
        XCTAssertEqual(consumed?.dirtyRectangles, [PixelRect(x: 0, y: 0, width: 50, height: 50)])
    }

    func testDamageSpanningTheWholeSurfaceCollapsesToFullDamage() {
        let store = LatestDesktopFrameStore()
        store.submit(frame(id: 1, dirty: [PixelRect(x: 0, y: 0, width: 50, height: 100)]))
        store.submit(frame(id: 2, dirty: [PixelRect(x: 50, y: 0, width: 50, height: 100)]))
        XCTAssertEqual(store.consume()?.dirtyRectangles, [])
    }

    func testAResizedSurfaceEscalatesToFullDamage() {
        let store = LatestDesktopFrameStore()
        store.submit(frame(id: 1, dirty: [PixelRect(x: 0, y: 0, width: 4, height: 4)]))
        store.submit(frame(
            id: 2,
            width: 200,
            height: 200,
            surfaceGeneration: 2,
            dirty: [PixelRect(x: 0, y: 0, width: 4, height: 4)]
        ))
        let consumed = store.consume()
        XCTAssertEqual(consumed?.width, 200)
        XCTAssertEqual(consumed?.dirtyRectangles, [])
    }

    func testANewGenerationNeverInheritsTheOldOnesDamage() {
        let store = LatestDesktopFrameStore()
        store.submit(frame(id: 1, dirty: [PixelRect(x: 0, y: 0, width: 4, height: 4)]))
        store.submit(frame(
            id: 2,
            generation: SessionGeneration(2),
            dirty: [PixelRect(x: 10, y: 10, width: 4, height: 4)]
        ))
        XCTAssertEqual(store.consume()?.dirtyRectangles, [])
    }

    func testAFrameThatSupersedesAFullDamageFrameStaysFullDamage() {
        let store = LatestDesktopFrameStore()
        store.submit(frame(id: 1, dirty: []))
        store.submit(frame(id: 2, dirty: [PixelRect(x: 1, y: 1, width: 2, height: 2)]))
        XCTAssertEqual(store.consume()?.dirtyRectangles, [])
    }

    func testABurstRaisesOneSignalUntilItIsConsumed() {
        let store = LatestDesktopFrameStore()
        let counter = SignalCounter()
        store.setSignal { counter.increment() }

        store.submit(frame(id: 1, dirty: []))
        store.submit(frame(id: 2, dirty: []))
        store.submit(frame(id: 3, dirty: []))
        XCTAssertEqual(counter.value, 1)

        _ = store.consume()
        store.submit(frame(id: 4, dirty: []))
        XCTAssertEqual(counter.value, 2)
    }

    func testASurfaceThatAttachesLateStillLearnsAboutTheWaitingFrame() {
        let store = LatestDesktopFrameStore()
        store.submit(frame(id: 1, dirty: []))
        let counter = SignalCounter()
        store.setSignal { counter.increment() }
        XCTAssertEqual(counter.value, 1)
    }

    func testDiscardingReleasesTheWaitingFrame() {
        let store = LatestDesktopFrameStore()
        store.submit(frame(id: 1, dirty: []))
        store.discardPending()
        XCTAssertNil(store.consume())

        let counter = SignalCounter()
        store.setSignal { counter.increment() }
        XCTAssertEqual(counter.value, 0)
    }

    func testStatisticsCountWhatTheRendererMissed() {
        let store = LatestDesktopFrameStore()
        store.submit(frame(id: 1, dirty: []))
        store.submit(frame(id: 2, dirty: []))
        _ = store.consume()
        store.submit(frame(id: 3, dirty: []))
        let statistics = store.statistics
        XCTAssertEqual(statistics.submitted, 3)
        XCTAssertEqual(statistics.coalesced, 1)
    }

    func testConcurrentSubmitsNeverLoseTheNewestSurface() {
        let store = LatestDesktopFrameStore()
        let group = DispatchGroup()
        for index in 1...200 {
            DispatchQueue.global().async(group: group) {
                store.submit(self.frame(id: UInt64(index), dirty: []))
            }
        }
        group.wait()
        XCTAssertNotNil(store.consume())
        XCTAssertEqual(store.statistics.submitted, 200)
    }

    // MARK: - Retained surface

    func testANewSurfaceIsSeededWithTheLastDrawnFrameAsAFullRepaint() {
        let store = LatestDesktopFrameStore()
        store.submit(frame(id: 1, dirty: [PixelRect(x: 0, y: 0, width: 1, height: 1)]))
        _ = store.consume()
        XCTAssertNil(store.consume())

        store.reseedForNewSurface()
        let seeded = store.consume()
        XCTAssertEqual(seeded?.frameID, 1)
        XCTAssertEqual(seeded?.dirtyRectangles, [])
    }

    func testReseedingNeverReplacesANewerPendingFrame() {
        let store = LatestDesktopFrameStore()
        store.submit(frame(id: 1, dirty: [PixelRect(x: 0, y: 0, width: 1, height: 1)]))
        _ = store.consume()
        store.submit(frame(id: 2, dirty: [PixelRect(x: 0, y: 0, width: 1, height: 1)]))
        store.reseedForNewSurface()
        XCTAssertEqual(store.consume()?.frameID, 2)
    }

    func testDiscardingTheRetainedSurfaceLeavesNothingToSeed() {
        let store = LatestDesktopFrameStore()
        store.submit(frame(id: 1, dirty: [PixelRect(x: 0, y: 0, width: 1, height: 1)]))
        _ = store.consume()
        XCTAssertTrue(store.hasRetainedSurface)
        store.discardRetained()
        store.reseedForNewSurface()
        XCTAssertNil(store.consume())
    }

}

/// A counter the store's `@Sendable` signal can close over.
private final class SignalCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
