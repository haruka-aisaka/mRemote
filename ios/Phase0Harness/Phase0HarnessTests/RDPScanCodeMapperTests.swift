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
        XCTAssertThrowsError(
            try RDPScanCodeMapper.set1ScanCode(forHIDUsage: 0x04)
        ) { error in
            XCTAssertEqual(
                error as? RDPScanCodeMappingError,
                .unsupportedHIDUsage(0x04)
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
