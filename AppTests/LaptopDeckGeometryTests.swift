import XCTest
@testable import mRemote

/// docs/changes/2026-11-03-deck-trackpad-and-home-bar.md: the keys keep
/// their shape, the pad takes what is left, and goes when that is too
/// little.
final class LaptopDeckGeometryTests: XCTestCase {
    /// A function row 0.7 high and five full rows, fifteen keys across.
    private let rows = LaptopDeckGeometry.Rows(heights: [0.7, 1, 1, 1, 1, 1], units: 15)
    private let halves = LaptopDeckGeometry.Rows(heights: [0.7, 1, 1, 1, 1, 1], units: 8)

    private func layout(
        _ size: CGSize,
        _ arrangement: LaptopDeckArrangement = .keyboardAboveTrackpad,
        split: Bool = false,
        buttons: Bool = true
    ) -> LaptopDeckGeometry {
        LaptopDeckGeometry.layout(
            in: CGRect(origin: CGPoint(x: 6, y: 6), size: size),
            arrangement: arrangement,
            rows: rows,
            halfRows: split ? halves : nil,
            hasButtons: buttons
        )
    }

    /// A one-unit key's cap, as LaptopDeckView draws it: inset by the gap
    /// across, a row high down.
    private func capSize(of keyboard: CGRect, rows: LaptopDeckGeometry.Rows) -> CGSize {
        let gap = LaptopDeckGeometry.rowGap
        let unitWidth = keyboard.width / CGFloat(rows.units)
        let unitHeight = (keyboard.height - gap * CGFloat(rows.heights.count - 1)) / CGFloat(rows.totalHeight)
        return CGSize(width: unitWidth - gap, height: unitHeight)
    }

    func testThePadTakesTheRestBelowAWholeWidthKeyboardOfSquareKeys() throws {
        let geometry = layout(CGSize(width: 380, height: 360))
        let keyboard = try XCTUnwrap(geometry.keyboard)
        XCTAssertEqual(keyboard.width, 380)
        XCTAssertEqual(keyboard.minY, 6, "keyboard above the pad")
        let cap = capSize(of: keyboard, rows: rows)
        XCTAssertEqual(cap.width, cap.height, accuracy: 0.001, "square keys")
        let pad = try XCTUnwrap(geometry.pad)
        XCTAssertEqual(pad.minY, keyboard.maxY + LaptopDeckGeometry.spacing, accuracy: 0.001)
        let button = try XCTUnwrap(geometry.leftButton)
        XCTAssertEqual(button.maxY, 366, accuracy: 0.001, "the buttons reach the deck's foot")
    }

    func testATallerDeckGrowsOnlyThePad() throws {
        let short = layout(CGSize(width: 380, height: 360))
        let tall = layout(CGSize(width: 380, height: 520))
        XCTAssertEqual(short.keyboard, tall.keyboard)
        XCTAssertGreaterThan(try XCTUnwrap(tall.pad).height, try XCTUnwrap(short.pad).height + 150)
    }

    func testThePadAboveTheKeyboardLeavesTheKeysAtTheFoot() throws {
        let geometry = layout(CGSize(width: 380, height: 360), .trackpadAboveKeyboard)
        XCTAssertEqual(try XCTUnwrap(geometry.keyboard).maxY, 366, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(geometry.pad).minY, 6)
    }

    func testAPadTooShortGoesAndTheKeyboardShrinksInTheMiddle() throws {
        // A phone on its side with the deck at half the height.
        let geometry = layout(CGSize(width: 840, height: 140))
        XCTAssertNil(geometry.pad)
        XCTAssertNil(geometry.leftButton)
        let keyboard = try XCTUnwrap(geometry.keyboard)
        XCTAssertEqual(keyboard.height, 140, accuracy: 0.001)
        XCTAssertLessThan(keyboard.width, 840)
        XCTAssertEqual(keyboard.midX, 6 + 420, accuracy: 0.001, "centred across")
        let cap = capSize(of: keyboard, rows: rows)
        XCTAssertEqual(cap.width, cap.height, accuracy: 0.001, "still square keys")
    }

    func testThePadIsMeasuredWithoutItsButtons() {
        let keyboardHeight = rows.height(forWidth: 380)
        let spacing = LaptopDeckGeometry.spacing
        // With buttons, 80 below the keys leaves 80 - 17.6 - 6 < 60 for the pad ...
        XCTAssertNil(layout(CGSize(width: 380, height: keyboardHeight + spacing + 80)).pad)
        // ... while without them all 80 is the pad's.
        XCTAssertNotNil(layout(CGSize(width: 380, height: keyboardHeight + spacing + 80), buttons: false).pad)
        XCTAssertNotNil(layout(CGSize(width: 380, height: keyboardHeight + spacing + 90)).pad)
    }

    /// The iPhone Duo bent like a laptop: the lower half, less the shortcut
    /// strip and the margin, still has a pad under square keys.
    func testTheDuoAtItsHingeKeepsItsPad() throws {
        let geometry = layout(CGSize(width: 466 - 12, height: 339 - 34 - 12))
        XCTAssertEqual(try XCTUnwrap(geometry.pad).height, 82, accuracy: 1)
    }

    func testKeyboardOnlyHasNoPadWhateverTheRoom() throws {
        let geometry = layout(CGSize(width: 380, height: 600), .keyboardOnly)
        XCTAssertNil(geometry.pad)
        let keyboard = try XCTUnwrap(geometry.keyboard)
        XCTAssertEqual(keyboard.width, 380)
        XCTAssertEqual(keyboard.midY, 306, accuracy: 0.001, "in the middle")
    }

    func testSplitHalvesKeepSquareKeysWithThePadBetween() throws {
        let geometry = layout(CGSize(width: 1340, height: 250), split: true)
        let left = try XCTUnwrap(geometry.leftHalf)
        let right = try XCTUnwrap(geometry.rightHalf)
        XCTAssertEqual(left.height, 250, accuracy: 0.001, "as tall as the deck allows")
        XCTAssertEqual(left.size, right.size)
        let cap = capSize(of: left, rows: halves)
        XCTAssertEqual(cap.width, cap.height, accuracy: 0.001)
        let pad = try XCTUnwrap(geometry.pad)
        XCTAssertEqual(pad.minX, left.maxX + LaptopDeckGeometry.spacing, accuracy: 0.001)
    }

    func testASplitPadTooNarrowGoes() throws {
        let geometry = layout(CGSize(width: 1340, height: 700), split: true)
        XCTAssertNil(geometry.pad)
        let left = try XCTUnwrap(geometry.leftHalf)
        XCTAssertLessThan(left.height, 700, "halves no wider than the screen allows")
        XCTAssertEqual(left.maxY, 706, accuracy: 0.001, "at the foot, for the thumbs")
        let cap = capSize(of: left, rows: halves)
        XCTAssertEqual(cap.width, cap.height, accuracy: 0.001)
    }
}
