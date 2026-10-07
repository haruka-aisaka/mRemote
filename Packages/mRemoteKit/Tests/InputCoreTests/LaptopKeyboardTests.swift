import XCTest
import RDPProtocol
import SessionCore
@testable import InputCore

final class LaptopKeyboardTests: XCTestCase {
    private func keys(_ events: [KeyboardInput]) -> [String] {
        events.map { String(format: "%02X%@", $0.usage, $0.transition == .down ? "v" : "^") }
    }

    private func key(_ id: String, in layout: KeyboardLayoutPreference = .japanese) -> LaptopKey {
        LaptopKeyboardLayout(layout).keys.first { $0.id == id }!
    }

    // MARK: - Layout

    func testEveryRowFillsTheSameWidth() {
        for preference in KeyboardLayoutPreference.allCases {
            for (index, row) in LaptopKeyboardLayout(preference).rows.enumerated() {
                XCTAssertEqual(
                    row.totalWidth,
                    LaptopKeyboardLayout.unitsPerRow,
                    accuracy: 0.001,
                    "\(preference) row \(index)"
                )
            }
        }
    }

    func testKeyIdentifiersAreUniqueExceptForAKeySpanningTwoRows() {
        for preference in KeyboardLayoutPreference.allCases {
            let rows = LaptopKeyboardLayout(preference).rows
            var rowsOfID: [String: [Int]] = [:]
            var keyOfID: [String: LaptopKey] = [:]
            for (index, row) in rows.enumerated() {
                let ids = row.keys.map(\.id)
                XCTAssertEqual(Set(ids).count, ids.count, "\(preference) row \(index)")
                for key in row.keys {
                    rowsOfID[key.id, default: []].append(index)
                    if let first = keyOfID[key.id] {
                        XCTAssertEqual(first.kind, key.kind, "\(key.id) is one key")
                    }
                    keyOfID[key.id] = key
                }
            }
            for (id, indices) in rowsOfID where indices.count > 1 {
                XCTAssertEqual(indices.count, 2, "\(id) spans at most two rows")
                XCTAssertEqual(indices[1], indices[0] + 1, "\(id) spans adjacent rows")
            }
            XCTAssertEqual(
                LaptopKeyboardLayout(preference).keys.count,
                rowsOfID.count,
                "keys lists a spanning key once"
            )
        }
    }

    func testTheJISEnterIsOneKeyAcrossTwoRows() {
        let rows = LaptopKeyboardLayout(.japanese).rows
        XCTAssertEqual(rows[2].keys.last?.id, "enter")
        XCTAssertEqual(rows[3].keys.last?.id, "enter")
        XCTAssertGreaterThan(rows[2].keys.last!.width, rows[3].keys.last!.width, "an inverted L")
        XCTAssertEqual(LaptopKeyboardLayout(.us).keys.filter { $0.id == "enter" }.count, 1)
    }

    func testEveryKeyReachesTheHost() {
        for preference in KeyboardLayoutPreference.allCases {
            for key in LaptopKeyboardLayout(preference).keys {
                let usage: UInt16
                switch key.kind {
                case .key(let value): usage = value
                case .modifier(let modifier): usage = modifier.usage
                }
                XCTAssertNoThrow(
                    try RDPScanCodeMapper.set1ScanCode(forHIDUsage: usage),
                    "\(preference) \(key.id)"
                )
            }
        }
    }

    func testTheJapaneseLayoutHasTheIMEKeys() {
        let ids = Set(LaptopKeyboardLayout(.japanese).keys.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: ["zenkaku", "eisu", "nonconvert", "convert", "kana", "ro", "yen"]))
        XCTAssertFalse(Set(LaptopKeyboardLayout(.us).keys.map(\.id)).contains("kana"))
    }

    func testTheJISArrowsFormAnInvertedT() {
        let rows = LaptopKeyboardLayout(.japanese).rows
        func start(of id: String, in row: LaptopKeyboardRow) -> Double? {
            var x = 0.0
            for key in row.keys {
                if key.id == id { return x }
                x += key.width
            }
            return nil
        }
        XCTAssertEqual(start(of: "up", in: rows[4]), start(of: "down", in: rows[5]))
        XCTAssertEqual(rows[4].keys.last?.id, "shift-right")
    }

    func testIMEKeysDoNotRepeat() {
        XCTAssertFalse(key("zenkaku").repeats)
        XCTAssertFalse(key("convert").repeats)
        XCTAssertTrue(key("backspace").repeats)
        XCTAssertTrue(key("left").repeats)
        XCTAssertFalse(key("shift-left").repeats)
    }

    // MARK: - Keys

    func testAKeyIsDownForAsLongAsItIsTouched() {
        var composer = LaptopKeyboardComposer()
        XCTAssertEqual(keys(composer.touchDown(key("a"))), ["04v"])
        XCTAssertTrue(composer.isDown(usage: 0x04))
        XCTAssertEqual(composer.repeatDown(usage: 0x04)?.isRepeat, true)
        XCTAssertEqual(keys(composer.touchUp(key("a"))), ["04^"])
        XCTAssertNil(composer.repeatDown(usage: 0x04))
    }

    func testASecondFingerOnAKeyAlreadyDownIsNotASecondPress() {
        var composer = LaptopKeyboardComposer()
        XCTAssertEqual(keys(composer.touchDown(key("enter"))), ["28v"])
        XCTAssertEqual(keys(composer.touchDown(key("enter"))), [])
        XCTAssertEqual(keys(composer.touchUp(key("enter"))), ["28^"])
        XCTAssertEqual(keys(composer.touchUp(key("enter"))), [])
    }

    // MARK: - Modifiers

    func testAHeldModifierAppliesToTheKeysTypedUnderIt() {
        var composer = LaptopKeyboardComposer()
        XCTAssertEqual(keys(composer.touchDown(key("control-left"))), [])
        XCTAssertEqual(keys(composer.touchDown(key("c"))), ["E0v", "06v"])
        XCTAssertEqual(keys(composer.touchUp(key("c"))), ["06^", "E0^"])
        XCTAssertEqual(keys(composer.touchDown(key("v"))), ["E0v", "19v"])
        XCTAssertEqual(keys(composer.touchUp(key("v"))), ["19^", "E0^"])
        XCTAssertEqual(keys(composer.touchUp(key("control-left"))), [])
        XCTAssertFalse(composer.isActive(.control), "a chord's modifier does not latch")
    }

    func testATappedModifierLatchesForOneKey() {
        var composer = LaptopKeyboardComposer()
        _ = composer.touchDown(key("shift-left"))
        _ = composer.touchUp(key("shift-left"))
        XCTAssertEqual(composer.latches.latch(.shift), .oneShot)
        XCTAssertEqual(keys(composer.touchDown(key("a"))), ["E1v", "04v"])
        XCTAssertFalse(composer.isActive(.shift), "spent at the key's down")
        XCTAssertEqual(keys(composer.touchUp(key("a"))), ["04^", "E1^"])
        XCTAssertEqual(keys(composer.touchDown(key("b"))), ["05v"])
    }

    func testTappingTwiceLocks() {
        var composer = LaptopKeyboardComposer()
        for _ in 0..<2 {
            _ = composer.touchDown(key("control-left"))
            _ = composer.touchUp(key("control-left"))
        }
        XCTAssertEqual(composer.latches.latch(.control), .locked)
        _ = composer.touchDown(key("a"))
        _ = composer.touchUp(key("a"))
        XCTAssertEqual(composer.latches.latch(.control), .locked)
    }

    func testOneFingerTypesCtrlAltDelete() {
        var composer = LaptopKeyboardComposer()
        for id in ["control-left", "alt-left"] {
            _ = composer.touchDown(key(id))
            _ = composer.touchUp(key(id))
        }
        XCTAssertEqual(keys(composer.touchDown(key("delete"))), ["E0v", "E2v", "4Cv"])
        XCTAssertEqual(keys(composer.touchUp(key("delete"))), ["4C^", "E2^", "E0^"])
    }

    func testOverlappingKeysShareTheModifierUntilTheLastIsReleased() {
        var composer = LaptopKeyboardComposer()
        _ = composer.touchDown(key("shift-left"))
        XCTAssertEqual(keys(composer.touchDown(key("a"))), ["E1v", "04v"])
        XCTAssertEqual(keys(composer.touchDown(key("b"))), ["05v"])
        XCTAssertEqual(keys(composer.touchUp(key("a"))), ["04^"])
        XCTAssertEqual(keys(composer.touchUp(key("b"))), ["05^", "E1^"])
    }

    func testBothShiftKeysAreOneModifier() {
        var composer = LaptopKeyboardComposer()
        _ = composer.touchDown(key("shift-left"))
        _ = composer.touchDown(key("shift-right"))
        _ = composer.touchUp(key("shift-left"))
        XCTAssertTrue(composer.isActive(.shift), "still held by the other key")
        _ = composer.touchUp(key("shift-right"))
        XCTAssertEqual(composer.latches.latch(.shift), .oneShot)
    }

    func testReleaseAllLeavesNothingDown() {
        var composer = LaptopKeyboardComposer()
        _ = composer.touchDown(key("control-left"))
        _ = composer.touchDown(key("a"))
        _ = composer.touchDown(key("left"))
        XCTAssertEqual(keys(composer.releaseAll()), ["04^", "50^", "E0^"])
        XCTAssertFalse(composer.isAnyKeyDown)
        XCTAssertFalse(composer.isActive(.control))
        XCTAssertEqual(keys(composer.touchUp(key("a"))), [], "the finger lifting later sends nothing")
        XCTAssertEqual(keys(composer.touchUp(key("control-left"))), [])
        XCTAssertFalse(composer.isActive(.control), "nor does it latch")
    }
}

final class RelativePointerMotionTests: XCTestCase {
    func testSlowTravelFollowsTheDrawingScale() {
        var motion = RelativePointerMotion()
        let next = motion.next(
            from: PixelPoint(x: 100, y: 100),
            dx: 10, dy: -5,
            pixelsPerPoint: 2, speed: 50,
            desktopWidth: 1920, desktopHeight: 1080
        )
        XCTAssertEqual(next, PixelPoint(x: 120, y: 90))
    }

    func testFractionsAccumulate() {
        var motion = RelativePointerMotion()
        var pixel = PixelPoint(x: 10, y: 10)
        for _ in 0..<4 {
            pixel = motion.next(
                from: pixel, dx: 0.3, dy: 0,
                pixelsPerPoint: 1, speed: 10,
                desktopWidth: 100, desktopHeight: 100
            )
        }
        XCTAssertEqual(pixel.x, 11, "1.2 pixels of travel is one pixel, not zero")
    }

    func testFastTravelIsAccelerated() {
        XCTAssertEqual(RelativePointerMotion.gain(forSpeed: 0), 1)
        XCTAssertGreaterThan(RelativePointerMotion.gain(forSpeed: 600), 1)
        XCTAssertEqual(RelativePointerMotion.gain(forSpeed: 10_000), RelativePointerMotion.maximumGain)
        XCTAssertEqual(RelativePointerMotion.gain(forSpeed: .nan), 1)
    }

    func testThePointerStopsAtTheEdgeAndComesStraightBack() {
        var motion = RelativePointerMotion()
        var pixel = motion.next(
            from: PixelPoint(x: 5, y: 5), dx: -500, dy: 0,
            pixelsPerPoint: 1, speed: 0,
            desktopWidth: 100, desktopHeight: 100
        )
        XCTAssertEqual(pixel.x, 0)
        pixel = motion.next(
            from: pixel, dx: 3, dy: 0,
            pixelsPerPoint: 1, speed: 0,
            desktopWidth: 100, desktopHeight: 100
        )
        XCTAssertEqual(pixel.x, 3)
        pixel = motion.next(
            from: pixel, dx: 500, dy: 500,
            pixelsPerPoint: 1, speed: 0,
            desktopWidth: 100, desktopHeight: 100
        )
        XCTAssertEqual(pixel, PixelPoint(x: 99, y: 99))
    }

    func testRouterMovesToAPixelOnce() {
        var router = PointerInputRouter(transform: ViewportTransform(
            desktopWidth: 100, desktopHeight: 100,
            viewport: ViewportSize(width: 100, height: 100)
        ))
        XCTAssertNil(router.knownPixel)
        XCTAssertEqual(router.moved(toPixel: PixelPoint(x: 3, y: 4)), [.move(PixelPoint(x: 3, y: 4))])
        XCTAssertEqual(router.moved(toPixel: PixelPoint(x: 3, y: 4)), [])
        XCTAssertEqual(router.knownPixel, PixelPoint(x: 3, y: 4))
        XCTAssertEqual(
            router.buttonsChanged(to: [.left]),
            [.button(.left, .down, at: PixelPoint(x: 3, y: 4))]
        )
    }
}
