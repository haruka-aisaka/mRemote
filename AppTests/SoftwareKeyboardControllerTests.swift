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

    func testAnArmedPasteSendsTheNextCommitByPasteOnce() {
        var pasted: [String] = []
        let controller = SoftwareKeyboardController(
            mode: .localIME,
            layout: .japanese,
            canSend: { [unowned self] in gateOpen },
            paste: { pasted.append($0) },
            send: { [unowned self] in sent.append($0) }
        )
        XCTAssertTrue(controller.canPaste)
        controller.togglePasteNextCommit()
        controller.commit("😀")
        XCTAssertEqual(pasted, ["😀"])
        XCTAssertEqual(sent, [], "pasted, not typed")
        XCTAssertFalse(controller.pastesNextCommit, "one shot")
        controller.commit("a")
        XCTAssertEqual(sent, [.unicode(0x61)])
        XCTAssertEqual(pasted.count, 1)
    }

    func testNoPasteWithoutAClipboardThatMaySend() {
        let controller = makeController()
        XCTAssertFalse(controller.canPaste)
        controller.togglePasteNextCommit()
        XCTAssertFalse(controller.pastesNextCommit)
    }

    func testHidingDisarmsThePaste() {
        let controller = SoftwareKeyboardController(
            mode: .localIME, layout: .japanese, canSend: { true }, paste: { _ in }, send: { _ in }
        )
        controller.togglePasteNextCommit()
        controller.hide()
        XCTAssertFalse(controller.pastesNextCommit)
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
