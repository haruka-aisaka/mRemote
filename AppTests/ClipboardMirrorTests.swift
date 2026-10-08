import XCTest
@testable import mRemote

final class ClipboardMirrorTests: XCTestCase {
    func testWhatTheMacHoldsIsOfferedWhenTheSessionStarts() {
        var mirror = ClipboardMirror()
        XCTAssertTrue(mirror.takeLocalChange(changeCount: 7))
        XCTAssertFalse(mirror.takeLocalChange(changeCount: 7))
        XCTAssertTrue(mirror.takeLocalChange(changeCount: 8))
    }

    func testTheMirrorsOwnWriteIsNotSentBack() {
        var mirror = ClipboardMirror()
        _ = mirror.takeLocalChange(changeCount: 1)
        XCTAssertTrue(mirror.shouldWrite("from windows"))
        mirror.wrote(changeCount: 2)
        XCTAssertFalse(mirror.takeLocalChange(changeCount: 2))
    }

    func testTextThatComesStraightBackIsNotTransferredAgain() {
        var mirror = ClipboardMirror()
        XCTAssertTrue(mirror.shouldOffer("from mac"))
        // The server announcing back what it was just given.
        XCTAssertFalse(mirror.shouldWrite("from mac"))
        XCTAssertTrue(mirror.shouldWrite("copied in windows"))
        XCTAssertFalse(mirror.shouldOffer("copied in windows"))
    }

    func testAnImageInBetweenMakesTheSameTextNewAgain() {
        var mirror = ClipboardMirror()
        XCTAssertTrue(mirror.shouldOffer("a"))
        mirror.forgetText()
        XCTAssertTrue(mirror.shouldOffer("a"))
    }
}
