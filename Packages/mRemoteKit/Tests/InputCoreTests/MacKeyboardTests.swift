import XCTest
@testable import InputCore

final class MacKeyboardTests: XCTestCase {
    func testJapaneseKeysBecomeTheUsagesAnIPadReports() {
        // 英数/かな are the reason the app exists: on the Mac they must reach
        // the router as LANG2/LANG1, exactly like UIKit's on an iPad.
        XCTAssertEqual(MacVirtualKey.usage(for: 102), 0x91) // kVK_JIS_Eisu
        XCTAssertEqual(MacVirtualKey.usage(for: 104), 0x90) // kVK_JIS_Kana
        XCTAssertEqual(MacVirtualKey.usage(for: 94), 0x87)  // kVK_JIS_Underscore, ろ
        XCTAssertEqual(MacVirtualKey.usage(for: 93), 0x89)  // kVK_JIS_Yen
    }

    func testKeysMapByPosition() {
        XCTAssertEqual(MacVirtualKey.usage(for: 0), 0x04)   // A
        XCTAssertEqual(MacVirtualKey.usage(for: 6), 0x1D)   // Z
        XCTAssertEqual(MacVirtualKey.usage(for: 29), 0x27)  // 0
        XCTAssertEqual(MacVirtualKey.usage(for: 51), 0x2A)  // Delete is Backspace
        XCTAssertEqual(MacVirtualKey.usage(for: 117), 0x4C) // Forward Delete
        XCTAssertEqual(MacVirtualKey.usage(for: 122), 0x3A) // F1
        XCTAssertEqual(MacVirtualKey.usage(for: 111), 0x45) // F12
        XCTAssertEqual(MacVirtualKey.usage(for: 126), 0x52) // Up
    }

    func testNoTwoKeysShareAUsage() {
        var seen: [UInt16: UInt16] = [:]
        for code in UInt16(0)...127 {
            guard let usage = MacVirtualKey.usage(for: code) else { continue }
            XCTAssertNil(seen[usage], "codes \(seen[usage] ?? 0) and \(code) both map to \(usage)")
            seen[usage] = code
        }
    }

    func testModifiersAreNotOrdinaryKeys() {
        // Modifiers arrive as flagsChanged and are told apart by their device
        // bit, so they must not also be in the key table.
        for code: UInt16 in [54, 55, 56, 58, 59, 60, 61, 62, MacVirtualKey.capsLock, 63] {
            XCTAssertNil(MacVirtualKey.usage(for: code), "\(code)")
        }
        XCTAssertEqual(MacVirtualKey.modifier(for: 55)?.usage, 0xE3) // Command is Windows
        XCTAssertEqual(MacVirtualKey.modifier(for: 58)?.usage, 0xE2) // Option is Alt
        XCTAssertEqual(MacVirtualKey.modifier(for: 62)?.usage, 0xE4)
        XCTAssertNil(MacVirtualKey.modifier(for: 63)) // Fn has no host key
        let bits = [54, 55, 56, 58, 59, 60, 61, 62].compactMap { MacVirtualKey.modifier(for: $0)?.deviceFlag }
        XCTAssertEqual(Set(bits).count, 8)
    }

    func testModifierStateComesFromItsOwnSide() {
        let leftCommand = MacVirtualKey.modifier(for: 55)!
        let rightCommand = MacVirtualKey.modifier(for: 54)!
        let command: UInt64 = 1 << 20
        // A keyboard: right Command still held while left is released.
        XCTAssertFalse(MacVirtualKey.isModifierDown(leftCommand, flags: command | 0x10))
        XCTAssertTrue(MacVirtualKey.isModifierDown(rightCommand, flags: command | 0x10))
        XCTAssertTrue(MacVirtualKey.isModifierDown(leftCommand, flags: command | 0x08))
        // Software-posted events carry only the device-independent flag.
        XCTAssertTrue(MacVirtualKey.isModifierDown(leftCommand, flags: command))
        XCTAssertFalse(MacVirtualKey.isModifierDown(leftCommand, flags: 0))
        XCTAssertTrue(MacVirtualKey.isModifierDown(MacVirtualKey.modifier(for: 58)!, flags: 1 << 19))
    }

    func testOnlyWindowShortcutsStayOnTheMac() {
        XCTAssertTrue(MacVirtualKey.isReservedForMac(keyCode: 12, command: true, control: false)) // ⌘Q
        XCTAssertTrue(MacVirtualKey.isReservedForMac(keyCode: 3, command: true, control: true))   // ⌃⌘F
        XCTAssertFalse(MacVirtualKey.isReservedForMac(keyCode: 3, command: true, control: false)) // ⌘F
        XCTAssertFalse(MacVirtualKey.isReservedForMac(keyCode: 13, command: true, control: false)) // ⌘W
        XCTAssertFalse(MacVirtualKey.isReservedForMac(keyCode: 8, command: true, control: false))  // ⌘C
        XCTAssertFalse(MacVirtualKey.isReservedForMac(keyCode: 12, command: false, control: true)) // ⌃Q
    }

    func testSoftwareFlagsGainALeftDeviceBit() {
        // ⌘ with no device bit (NSEvent.modifierFlags) reads as left ⌘.
        XCTAssertEqual(MacVirtualKey.withDeviceFlags(1 << 20), (1 << 20) | 0x08)
        // A right ⌘ already says which key it is.
        XCTAssertEqual(MacVirtualKey.withDeviceFlags((1 << 20) | 0x10), (1 << 20) | 0x10)
        // ⇧⌃ together.
        XCTAssertEqual(MacVirtualKey.withDeviceFlags((1 << 17) | (1 << 18)), (1 << 17) | (1 << 18) | 0x02 | 0x01)
        XCTAssertEqual(MacVirtualKey.withDeviceFlags(0), 0)
    }
}
