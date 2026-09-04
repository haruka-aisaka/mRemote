import XCTest
#if SWIFT_PACKAGE
@testable import Phase0HarnessLogic
#else
@testable import Phase0Harness
#endif

final class RDPScanCodeMapperTests: XCTestCase {
    func testMandatoryJapaneseKeysMapToSet1ScanCodes() throws {
        XCTAssertEqual(
            try RDPScanCodeMapper.set1ScanCode(forHIDUsage: HIDUsage.eisu),
            RDPSet1ScanCode(value: 0x7B, isExtended: false)
        )
        XCTAssertEqual(
            try RDPScanCodeMapper.set1ScanCode(forHIDUsage: HIDUsage.kana),
            RDPSet1ScanCode(value: 0x79, isExtended: false)
        )
    }

    func testUnknownUsageIsRejectedRatherThanGuessed() {
        for usage: UInt16 in [
            0x00, // reserved
            0x03, // reserved
            0x48, // Pause: an EXTENDED1 two-code sequence this event cannot carry
            0x66, // Power
            0xFF,
        ] {
            XCTAssertThrowsError(
                try RDPScanCodeMapper.set1ScanCode(forHIDUsage: usage)
            ) { error in
                XCTAssertEqual(
                    error as? RDPScanCodeMappingError,
                    .unsupportedHIDUsage(usage)
                )
            }
        }
    }

    func testPrintableKeysMapToTheirSet1Positions() throws {
        let expected: [UInt16: UInt8] = [
            0x04: 0x1E, // A
            0x0A: 0x22, // G
            0x14: 0x10, // Q
            0x1D: 0x2C, // Z
            0x1E: 0x02, // 1
            0x26: 0x0A, // 9
            0x27: 0x0B, // 0
            0x28: 0x1C, // Return
            0x29: 0x01, // Escape
            0x2A: 0x0E, // Backspace
            0x2B: 0x0F, // Tab
            0x2C: 0x39, // Space
            0x38: 0x35, // /
            0x64: 0x56, // Non-US backslash
        ]
        for (usage, value) in expected {
            XCTAssertEqual(
                try RDPScanCodeMapper.set1ScanCode(forHIDUsage: usage),
                RDPSet1ScanCode(value: value, isExtended: false),
                String(format: "HID 0x%02X", usage)
            )
        }
    }

    func testFunctionAndKeypadRowsSkipTheirDiscontinuities() throws {
        let expected: [UInt16: RDPSet1ScanCode] = [
            0x3A: RDPSet1ScanCode(value: 0x3B, isExtended: false), // F1
            0x43: RDPSet1ScanCode(value: 0x44, isExtended: false), // F10
            0x44: RDPSet1ScanCode(value: 0x57, isExtended: false), // F11
            0x45: RDPSet1ScanCode(value: 0x58, isExtended: false), // F12
            0x68: RDPSet1ScanCode(value: 0x64, isExtended: false), // F13
            0x72: RDPSet1ScanCode(value: 0x6E, isExtended: false), // F23
            0x73: RDPSet1ScanCode(value: 0x76, isExtended: false), // F24
            0x59: RDPSet1ScanCode(value: 0x4F, isExtended: false), // Keypad 1
            0x61: RDPSet1ScanCode(value: 0x49, isExtended: false), // Keypad 9
            0x62: RDPSet1ScanCode(value: 0x52, isExtended: false), // Keypad 0
            0x63: RDPSet1ScanCode(value: 0x53, isExtended: false), // Keypad .
            0x54: RDPSet1ScanCode(value: 0x35, isExtended: true), // Keypad /
            0x55: RDPSet1ScanCode(value: 0x37, isExtended: false), // Keypad *
            0x58: RDPSet1ScanCode(value: 0x1C, isExtended: true), // Keypad Enter
        ]
        for (usage, scanCode) in expected {
            XCTAssertEqual(
                try RDPScanCodeMapper.set1ScanCode(forHIDUsage: usage),
                scanCode,
                String(format: "HID 0x%02X", usage)
            )
        }
    }

    func testOnlyTheExtendedKeysCarryTheExtendedSelector() throws {
        let extendedUsages: Set<UInt16> = [
            0x46, // Print Screen
            0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, // Insert/Home/PageUp/Delete/End/PageDown
            0x4F, 0x50, 0x51, 0x52, // arrows
            0x54, 0x58, // Keypad / and Keypad Enter
            0x65, // Application
            0xE3, 0xE4, 0xE6, 0xE7, // Left GUI, Right Control, Right Alt, Right GUI
        ]
        for usage in UInt16(0x00)...UInt16(0xFF) {
            guard let scanCode = try? RDPScanCodeMapper.set1ScanCode(forHIDUsage: usage) else {
                continue
            }
            XCTAssertEqual(
                scanCode.isExtended,
                extendedUsages.contains(usage),
                String(format: "HID 0x%02X extended selector", usage)
            )
            XCTAssertNotEqual(scanCode.value, 0, "Set 1 code 0x00 is not sendable")
        }
    }

    func testModifiersDistinguishLeftFromRight() throws {
        XCTAssertEqual(
            try RDPScanCodeMapper.set1ScanCode(forHIDUsage: 0xE0),
            RDPSet1ScanCode(value: 0x1D, isExtended: false)
        )
        XCTAssertEqual(
            try RDPScanCodeMapper.set1ScanCode(forHIDUsage: 0xE4),
            RDPSet1ScanCode(value: 0x1D, isExtended: true)
        )
        XCTAssertEqual(
            try RDPScanCodeMapper.set1ScanCode(forHIDUsage: 0xE2),
            RDPSet1ScanCode(value: 0x38, isExtended: false)
        )
        XCTAssertEqual(
            try RDPScanCodeMapper.set1ScanCode(forHIDUsage: 0xE6),
            RDPSet1ScanCode(value: 0x38, isExtended: true)
        )
        XCTAssertEqual(
            try RDPScanCodeMapper.set1ScanCode(forHIDUsage: 0xE1),
            RDPSet1ScanCode(value: 0x2A, isExtended: false)
        )
        XCTAssertEqual(
            try RDPScanCodeMapper.set1ScanCode(forHIDUsage: 0xE5),
            RDPSet1ScanCode(value: 0x36, isExtended: false)
        )
    }

    func testJapaneseKeysFollowTheDocumentedMapping() throws {
        let expected: [UInt16: UInt8] = [
            0x87: 0x73, // Intl1, ろ
            0x88: 0x70, // Intl2, カナ
            0x89: 0x7D, // Intl3, ¥
            0x8A: 0x79, // Intl4, 変換
            0x8B: 0x7B, // Intl5, 無変換
            0x94: 0x29, // LANG5, 半角/全角
        ]
        for (usage, value) in expected {
            XCTAssertEqual(
                try RDPScanCodeMapper.set1ScanCode(forHIDUsage: usage),
                RDPSet1ScanCode(value: value, isExtended: false),
                String(format: "HID 0x%02X", usage)
            )
        }
    }

    func testRecordingDiagnosticIncludesExpectedSet1Code() {
        XCTAssertTrue(
            OutboundInput.hardwareKey(usage: HIDUsage.eisu, transition: .down)
                .diagnosticDescription.contains("set1=0x7B")
        )
        XCTAssertTrue(
            OutboundInput.hardwareKey(usage: HIDUsage.kana, transition: .up)
                .diagnosticDescription.contains("set1=0x79")
        )
    }

    func testPrintableUsageDiagnosticIsRedactedBeforeJournaling() {
        let description = OutboundInput.hardwareKey(usage: 0x04, transition: .down)
            .diagnosticDescription

        XCTAssertEqual(description, "hardware key details redacted")
        for forbidden in ["KeyboardA", "0x04", "HID=", "set1=", "down"] {
            XCTAssertFalse(description.contains(forbidden))
        }
    }
}
