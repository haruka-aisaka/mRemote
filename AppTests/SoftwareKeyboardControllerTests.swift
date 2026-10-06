import XCTest
import InputCore
import SessionCore
@testable import mRemote

@MainActor
final class SoftwareKeyboardControllerTests: XCTestCase {
    private var sent: [SoftwareKeyboardOutput] = []
    private var gateOpen = true

    private func makeController(mode: SoftwareKeyboardMode = .localIME) -> SoftwareKeyboardController {
        SoftwareKeyboardController(
            mode: mode,
            layout: .japanese,
            canSend: { [unowned self] in gateOpen },
            send: { [unowned self] in sent.append($0) }
        )
    }

    func testCommittedTextIsSentAndNothingWhileTheGateIsClosed() {
        let controller = makeController()
        controller.commit("あ")
        XCTAssertEqual(sent, [.unicode(0x3042)])
        gateOpen = false
        controller.commit("い")
        XCTAssertEqual(sent.count, 1)
    }

    func testEscapeCancelsACompositionBeforeItReachesTheHost() {
        let controller = makeController()
        controller.markedText = "にほ"
        controller.press(.escape)
        XCTAssertNil(controller.markedText)
        XCTAssertEqual(sent, [], "Esc only cancelled the composition")
        controller.press(.escape)
        XCTAssertEqual(sent.count, 2, "without a composition it is the remote's Esc")
    }

    func testModifiersAndModeAreRefusedWhileComposing() {
        let controller = makeController()
        controller.markedText = "か"
        controller.tapModifier(.control)
        XCTAssertEqual(controller.latch(.control), .off)
        controller.setMode(.hostIME)
        XCTAssertEqual(controller.mode, .localIME)
        controller.press(.tab)
        XCTAssertEqual(sent, [])
    }

    func testHidingReleasesEveryLatch() {
        let controller = makeController(mode: .hostIME)
        controller.show()
        controller.tapModifier(.control)
        controller.tapModifier(.control)
        XCTAssertEqual(controller.latch(.control), .locked)
        controller.hide()
        XCTAssertFalse(controller.isVisible)
        XCTAssertEqual(controller.latch(.control), .off)
    }
}
