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

    /// Every keyboard the deck can draw, named for failure messages.
    private var allLayouts: [(String, LaptopKeyboardLayout)] {
        KeyboardLayoutPreference.allCases.flatMap { preference in
            LaptopKeyboardPlatform.allCases.map { platform in
                ("\(platform) \(preference)", LaptopKeyboardLayout(preference, platform: platform))
            }
        }
    }

    func testEveryRowFillsTheSameWidth() {
        for (preference, layout) in allLayouts {
            for (index, row) in layout.rows.enumerated() {
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
        for (preference, layout) in allLayouts {
            let rows = layout.rows
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
                layout.keys.count,
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
        for (preference, layout) in allLayouts {
            for key in layout.keys {
                let usage: UInt16
                switch key.kind {
                case .key(let value): usage = value
                case .modifier(let modifier): usage = modifier.usage
                case .inert: continue
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
        XCTAssertTrue(ids.isSuperset(of: ["zenkaku", "capslock", "nonconvert", "convert", "kana", "ro", "yen"]))
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

    func testTheMacLayoutsSendCommandAndOptionAsWinAndAlt() {
        for preference in [KeyboardLayoutPreference.japanese, .us] {
            let keys = LaptopKeyboardLayout(preference, platform: .mac).keys
            let command = keys.first { $0.id == "command-left" }
            let option = keys.first { $0.id == "alt-left" }
            XCTAssertEqual(command?.kind, .modifier(.windows), "\(preference)")
            XCTAssertEqual(option?.kind, .modifier(.alt), "\(preference)")
            XCTAssertNil(keys.first { $0.id == "windows" }, "no Win key on a Mac")
        }
    }

    func testTheMacJISLayoutHasEisuAndKanaAsLANG2AndLANG1() {
        let keys = LaptopKeyboardLayout(.japanese, platform: .mac).keys
        XCTAssertEqual(keys.first { $0.id == "eisu" }?.kind, .key(0x91))
        XCTAssertEqual(keys.first { $0.id == "kana" }?.kind, .key(0x90))
        XCTAssertNil(keys.first { $0.id == "zenkaku" }, "a Mac has no 半/全")
        XCTAssertNil(keys.first { $0.id == "convert" })
        XCTAssertFalse(keys.first { $0.id == "eisu" }!.repeats)
        XCTAssertEqual(
            keys.first { $0.id == "control-left" }?.kind,
            .modifier(.control),
            "control sits left of A"
        )
    }

    func testEveryLayoutsArrowsFormAnInvertedT() {
        for (name, layout) in allLayouts where !(name.hasPrefix("windows") && !name.hasSuffix("japanese")) {
            let rows = layout.rows
            func start(of id: String, in row: LaptopKeyboardRow) -> Double? {
                var x = 0.0
                for key in row.keys {
                    if key.id == id { return x }
                    x += key.width
                }
                return nil
            }
            XCTAssertEqual(start(of: "up", in: rows[4]), start(of: "down", in: rows[5]), name)
        }
    }

    func testTheMacCapsLockKeyTakesTheRoleMacOSWasGiven() {
        let expected: [CapsLockRole: LaptopKey.Kind] = [
            .capsLock: .key(0x39),
            .control: .modifier(.control),
            .option: .modifier(.alt),
            .command: .modifier(.windows),
            .escape: .key(0x29),
            .noAction: .inert,
        ]
        for preference in [KeyboardLayoutPreference.japanese, .us] {
            for role in CapsLockRole.allCases {
                let layout = LaptopKeyboardLayout(preference, platform: .mac, capsLockRole: role)
                let caps = layout.keys.first { $0.id == "capslock" }
                XCTAssertEqual(caps?.kind, expected[role], "\(preference) \(role)")
                XCTAssertEqual(
                    layout.rows.map(\.totalWidth),
                    LaptopKeyboardLayout(preference, platform: .mac).rows.map(\.totalWidth),
                    "the role does not move other keys"
                )
            }
        }
    }

    func testTheWindowsCapsKeyIsCapsLockAndCanBecomeControl() {
        for preference in [KeyboardLayoutPreference.japanese, .us] {
            let caps = LaptopKeyboardLayout(preference).keys.first { $0.id == "capslock" }
            XCTAssertEqual(caps?.kind, .key(0x39), "\(preference)")
            XCTAssertEqual(caps?.label, "Caps", "\(preference)")
            let control = LaptopKeyboardLayout(preference, capsLockRole: .control)
                .keys.first { $0.id == "capslock" }
            XCTAssertEqual(control?.kind, .modifier(.control), "\(preference)")
            XCTAssertEqual(control?.label, "Ctrl", "\(preference)")
        }
        XCTAssertEqual(CapsLockRole.windowsRoles, [.capsLock, .control])
    }

    func testANoActionKeySendsNothingAndDoesNotLatch() {
        var composer = LaptopKeyboardComposer()
        let caps = LaptopKeyboardLayout(.japanese, platform: .mac, capsLockRole: .noAction)
            .keys.first { $0.id == "capslock" }!
        XCTAssertEqual(composer.touchDown(caps), [])
        XCTAssertEqual(composer.touchUp(caps), [])
        XCTAssertFalse(caps.repeats)
        XCTAssertFalse(caps.isModifier)
    }

    func testACapsLockActingAsControlChordsLikeControl() {
        var composer = LaptopKeyboardComposer()
        let layoutKeys = LaptopKeyboardLayout(.japanese, platform: .mac, capsLockRole: .control).keys
        let caps = layoutKeys.first { $0.id == "capslock" }!
        let c = layoutKeys.first { $0.id == "c" }!
        _ = composer.touchDown(caps)
        XCTAssertEqual(keys(composer.touchDown(c)), ["E0v", "06v"])
    }

    func testTheDefaultPlatformIsWindows() {
        XCTAssertEqual(LaptopKeyboardLayout(.japanese), LaptopKeyboardLayout(.japanese, platform: .windows))
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

    // MARK: - Windows key

    func testATappedWindowsKeyIsSentSoStartOpens() {
        var composer = LaptopKeyboardComposer()
        let win = key("windows")
        XCTAssertEqual(keys(composer.touchDown(win)), [])
        XCTAssertEqual(keys(composer.touchUp(win, heldFor: 0.1)), ["E3v", "E3^"])
        XCTAssertFalse(composer.isActive(.windows), "a tap is not a latch")
    }

    func testAHeldWindowsKeyLatchesForOneFingerChords() {
        var composer = LaptopKeyboardComposer()
        let win = key("windows")
        _ = composer.touchDown(win)
        XCTAssertEqual(keys(composer.touchUp(win, heldFor: 0.6)), [])
        XCTAssertEqual(composer.latches.latch(.windows), .oneShot)
        XCTAssertEqual(keys(composer.touchDown(key("r"))), ["E3v", "15v"])
        XCTAssertEqual(keys(composer.touchUp(key("r"))), ["15^", "E3^"])
    }

    func testTappingALatchedWindowsKeyMovesTheLatchOn() {
        var composer = LaptopKeyboardComposer()
        let win = key("windows")
        _ = composer.touchDown(win)
        _ = composer.touchUp(win, heldFor: 0.6)
        _ = composer.touchDown(win)
        XCTAssertEqual(keys(composer.touchUp(win, heldFor: 0.1)), [], "no Start while latched")
        XCTAssertEqual(composer.latches.latch(.windows), .locked)
    }

    func testAWindowsChordWithTwoFingersSendsNoExtraWindowsKey() {
        var composer = LaptopKeyboardComposer()
        let win = key("windows")
        _ = composer.touchDown(win)
        XCTAssertEqual(keys(composer.touchDown(key("e"))), ["E3v", "08v"])
        XCTAssertEqual(keys(composer.touchUp(key("e"))), ["08^", "E3^"])
        XCTAssertEqual(keys(composer.touchUp(win, heldFor: 0.1)), [])
    }

    func testTheWindowsKeyCarriesALatchedModifier() {
        var composer = LaptopKeyboardComposer()
        _ = composer.touchDown(key("shift-left"))
        _ = composer.touchUp(key("shift-left"))
        _ = composer.touchDown(key("windows"))
        XCTAssertEqual(keys(composer.touchUp(key("windows"))), ["E1v", "E3v", "E3^", "E1^"])
        XCTAssertFalse(composer.isActive(.shift), "the one-shot is spent")
    }

    func testOnlyTheWindowsKeySendsWhenTappedAlone() {
        for (name, layout) in allLayouts {
            let senders = layout.keys.filter(\.sendsWhenTappedAlone).map(\.id)
            XCTAssertEqual(senders, name.hasPrefix("windows") ? ["windows"] : [], name)
        }
        var composer = LaptopKeyboardComposer()
        _ = composer.touchDown(key("control-left"))
        XCTAssertEqual(keys(composer.touchUp(key("control-left"), heldFor: 0.1)), [], "Ctrl still latches")
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
