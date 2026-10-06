import XCTest
@testable import SessionCore

final class RemoteCursorTests: XCTestCase {
    func testPixelsArePremultipliedAndRepacked() {
        // Two pixels with a padded row: opaque red, and half-transparent white.
        let source: [UInt8] = [0, 0, 255, 255, 255, 255, 255, 128, 9, 9, 9, 9]
        let image = source.withUnsafeBytes {
            RemoteCursorImage(
                straightBGRA: $0, width: 2, height: 1,
                sourceBytesPerRow: 12, hotspotX: 1, hotspotY: 0
            )
        }
        XCTAssertEqual(image.map { Array($0.pixels) }, [0, 0, 255, 255, 128, 128, 128, 128])
        XCTAssertEqual(image?.bytesPerRow, 8)
    }

    func testGeometryThatDoesNotFitTheBufferIsRefused() {
        let source = [UInt8](repeating: 0, count: 15)
        source.withUnsafeBytes { bytes in
            XCTAssertNil(RemoteCursorImage(
                straightBGRA: bytes, width: 2, height: 2,
                sourceBytesPerRow: 8, hotspotX: 0, hotspotY: 0
            ))
            XCTAssertNil(RemoteCursorImage(
                straightBGRA: bytes, width: 1, height: 1,
                sourceBytesPerRow: 4, hotspotX: 1, hotspotY: 0
            ))
            XCTAssertNil(RemoteCursorImage(
                straightBGRA: bytes, width: 1, height: 1,
                sourceBytesPerRow: 3, hotspotX: 0, hotspotY: 0
            ))
        }
    }

    func testTheStoreSignalsOnlyOnChange() {
        let store = RemoteCursorStore()
        let count = LockedCounter()
        store.setSignal { count.increment() }
        store.submit(.systemDefault)
        store.submit(.hidden)
        store.submit(.hidden)
        store.reset()
        XCTAssertEqual(count.value, 2)
        XCTAssertEqual(store.cursor, .systemDefault)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
