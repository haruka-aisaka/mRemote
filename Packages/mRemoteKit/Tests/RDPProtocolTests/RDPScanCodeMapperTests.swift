import XCTest
@testable import RDPProtocol

final class RDPScanCodeMapperTests: XCTestCase {
    private func scanCode(_ usage: UInt16) throws -> RDPSet1ScanCode {
        try RDPScanCodeMapper.set1ScanCode(forHIDUsage: usage)
    }

    /// The reason the project exists, and the one row that must never change
    /// without a deliberate decision: iPadOS reports 英数 as LANG2 and かな as
    /// LANG1, and Windows has to see them as 無変換 and 変換.
    func testEisuBecomesMuhenkanAndKanaBecomesHenkan() throws {
        XCTAssertEqual(try scanCode(0x91), RDPSet1ScanCode(value: 0x7B, isExtended: false))
        XCTAssertEqual(try scanCode(0x90), RDPSet1ScanCode(value: 0x79, isExtended: false))
    }

    func testTheJISKeysKeepTheirOwnScanCodes() throws {
        XCTAssertEqual(try scanCode(0x87).value, 0x73) // ろ
        XCTAssertEqual(try scanCode(0x88).value, 0x70) // カナ
        XCTAssertEqual(try scanCode(0x89).value, 0x7D) // ¥
        XCTAssertEqual(try scanCode(0x8A).value, 0x79) // 変換
        XCTAssertEqual(try scanCode(0x8B).value, 0x7B) // 無変換
    }

    func testLettersAreMappedInHIDOrderNotAlphabeticalScanCodeOrder() throws {
        XCTAssertEqual(try scanCode(0x04).value, 0x1E) // A
        XCTAssertEqual(try scanCode(0x09).value, 0x21) // F
        XCTAssertEqual(try scanCode(0x1D).value, 0x2C) // Z
    }

    func testTheDigitRowRunsOneThroughNineThenZero() throws {
        XCTAssertEqual(try scanCode(0x1E).value, 0x02) // 1
        XCTAssertEqual(try scanCode(0x26).value, 0x0A) // 9
        XCTAssertEqual(try scanCode(0x27).value, 0x0B) // 0
    }

    func testFunctionKeysSkipTheGapAtF11() throws {
        XCTAssertEqual(try scanCode(0x3A).value, 0x3B) // F1
        XCTAssertEqual(try scanCode(0x43).value, 0x44) // F10
        XCTAssertEqual(try scanCode(0x44).value, 0x57) // F11
        XCTAssertEqual(try scanCode(0x45).value, 0x58) // F12
    }

    func testNavigationKeysCarryTheExtendedSelector() throws {
        // The selector is a flag on the event rather than a byte in the code,
        // because `mr_rdp_key_event` carries it separately.
        for usage in [0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x50, 0x51, 0x52] as [UInt16] {
            XCTAssertTrue(try scanCode(usage).isExtended, "usage 0x\(String(usage, radix: 16))")
        }
        XCTAssertEqual(try scanCode(0x52), RDPSet1ScanCode(value: 0x48, isExtended: true)) // Up
    }

    func testRightHandModifiersAreExtendedAndLeftHandOnesAreNot() throws {
        XCTAssertEqual(try scanCode(0xE0), RDPSet1ScanCode(value: 0x1D, isExtended: false))
        XCTAssertEqual(try scanCode(0xE4), RDPSet1ScanCode(value: 0x1D, isExtended: true))
        XCTAssertEqual(try scanCode(0xE1), RDPSet1ScanCode(value: 0x2A, isExtended: false))
        XCTAssertEqual(try scanCode(0xE5), RDPSet1ScanCode(value: 0x36, isExtended: false))
        XCTAssertEqual(try scanCode(0xE2), RDPSet1ScanCode(value: 0x38, isExtended: false))
        XCTAssertEqual(try scanCode(0xE6), RDPSet1ScanCode(value: 0x38, isExtended: true))
    }

    func testEveryModifierIsMappedSoNoneCanStickDown() throws {
        // A modifier that cannot be mapped is never sent, and a Control the
        // host thinks is held turns every later keystroke into a shortcut.
        for usage in UInt16(0xE0)...UInt16(0xE7) {
            XCTAssertNoThrow(try scanCode(usage), "usage 0x\(String(usage, radix: 16))")
        }
    }

    func testPauseIsRefusedRatherThanApproximated() {
        // Pause is an EXTENDED1 sequence of two scan codes, which a
        // single-code event cannot express. A wrong code would type something.
        XCTAssertThrowsError(try scanCode(0x48)) { error in
            XCTAssertEqual(
                error as? RDPScanCodeMappingError,
                .unsupportedHIDUsage(0x48)
            )
        }
    }

    func testAnUnknownUsageIsRefusedRatherThanGuessed() {
        XCTAssertThrowsError(try scanCode(0xFFFF))
        XCTAssertThrowsError(try scanCode(0x00))
    }

    func testNoTwoUsagesShareAScanCodeUnlessTheyShareAKeyPosition() throws {
        // Duplicates are legitimate only where two HID usages describe the
        // same physical key; anything else is a typo in the table that would
        // type the wrong character.
        let known: Set<Set<UInt16>> = [
            [0x31, 0x32], // backslash and non-US hash sit in the same position
            [0x35, 0x94], // grave and LANG5 半角/全角
            [0x8A, 0x90], // 変換 and かな both mean Convert
            [0x8B, 0x91], // 無変換 and 英数 both mean NonConvert
        ]
        var byScanCode: [String: Set<UInt16>] = [:]
        for usage in UInt16(0)...UInt16(0xFF) {
            guard let code = try? scanCode(usage) else { continue }
            byScanCode[code.description, default: []].insert(usage)
        }
        for (code, usages) in byScanCode where usages.count > 1 {
            XCTAssertTrue(
                known.contains(usages),
                "\(code) is shared by an unexpected set of usages: \(usages.sorted())"
            )
        }
    }
}
