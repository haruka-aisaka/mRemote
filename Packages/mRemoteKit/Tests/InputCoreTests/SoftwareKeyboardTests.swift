import XCTest
import SessionCore
@testable import InputCore

final class SoftwareKeyboardTests: XCTestCase {
    private func keys(_ output: [SoftwareKeyboardOutput]) -> [String] {
        output.map {
            switch $0 {
            case .key(let input):
                return String(format: "%02X%@", input.usage, input.transition == .down ? "v" : "^")
            case .unicode(let unit):
                return String(format: "U+%04X", unit)
            }
        }
    }

    // MARK: - Modifiers

    func testAModifierCyclesThroughOneShotLockAndOff() {
        var state = VirtualModifierState()
        state.tap(.control)
        XCTAssertEqual(state.latch(.control), .oneShot)
        state.tap(.control)
        XCTAssertEqual(state.latch(.control), .locked)
        state.keyWasSent()
        XCTAssertEqual(state.latch(.control), .locked, "a lock survives a key")
        state.tap(.control)
        XCTAssertEqual(state.latch(.control), .off)
    }

    func testAOneShotIsSpentByOneKey() {
        var state = VirtualModifierState()
        state.tap(.shift)
        state.keyWasSent()
        XCTAssertTrue(state.isEmpty)
    }

    // MARK: - Host IME mode

    func testHostModeTypesKeyPositionsForTheJapaneseLayout() {
        var composer = SoftwareKeyboardComposer(mode: .hostIME, layout: .japanese)
        // a, A (shift), @ (the key right of P on JIS), _ (Shift+ろ).
        XCTAssertEqual(keys(composer.commit("aA@_")), [
            "04v", "04^",
            "E1v", "04v", "04^", "E1^",
            "2Fv", "2F^",
            "E1v", "87v", "87^", "E1^",
        ])
    }

    func testTheSameCharacterIsADifferentKeyOnUSWindows() {
        let japanese = ASCIIKeystrokeMapper(layout: .japanese)
        let us = ASCIIKeystrokeMapper(layout: .us)
        XCTAssertEqual(japanese.keystroke(for: "@"), KeyStroke(usage: 0x2F))
        XCTAssertEqual(us.keystroke(for: "@"), KeyStroke(usage: 0x1F, shift: true))
        XCTAssertEqual(japanese.keystroke(for: ":"), KeyStroke(usage: 0x34))
        XCTAssertEqual(us.keystroke(for: ":"), KeyStroke(usage: 0x33, shift: true))
        XCTAssertNil(us.keystroke(for: "あ"))
    }

    func testEveryPrintableASCIICharacterHasAKeyOnBothLayouts() {
        for layout in [KeyboardLayoutPreference.japanese, .us] {
            let mapper = ASCIIKeystrokeMapper(layout: layout)
            for value in UInt8(0x20)...UInt8(0x7E) {
                let character = Character(UnicodeScalar(value))
                XCTAssertNotNil(mapper.keystroke(for: character), "\(layout) \(character)")
            }
        }
    }

    // MARK: - Local IME mode

    func testLocalModeSendsCommittedTextAsUnicodeIncludingSurrogates() {
        var composer = SoftwareKeyboardComposer(mode: .localIME, layout: .japanese)
        XCTAssertEqual(keys(composer.commit("あ😀")), ["U+3042", "U+D83D", "U+DE00"])
    }

    func testEnterIsAKeyEvenInLocalMode() {
        var composer = SoftwareKeyboardComposer(mode: .localIME, layout: .japanese)
        XCTAssertEqual(keys(composer.commit("\n")), ["28v", "28^"])
    }

    func testAModifierTurnsTheNextCharacterIntoAChordInLocalMode() {
        var composer = SoftwareKeyboardComposer(mode: .localIME, layout: .japanese)
        composer.tapModifier(.control)
        XCTAssertEqual(keys(composer.commit("c")), ["E0v", "06v", "06^", "E0^"])
        // The one-shot is spent: the next letter is text again.
        XCTAssertEqual(keys(composer.commit("c")), ["U+0063"])
    }

    func testLockedModifiersApplyToExtendedKeysAndAreNeverLeftHeld() {
        var composer = SoftwareKeyboardComposer(mode: .hostIME, layout: .japanese)
        composer.tapModifier(.alt)
        composer.tapModifier(.alt)
        XCTAssertEqual(keys(composer.press(.tab)), ["E2v", "2Bv", "2B^", "E2^"])
        XCTAssertEqual(keys(composer.press(.tab)), ["E2v", "2Bv", "2B^", "E2^"])
        composer.releaseModifiers()
        XCTAssertEqual(keys(composer.press(.convert)), ["8Av", "8A^"])
    }
}
