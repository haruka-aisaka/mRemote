import Foundation

/// A Set 1 scan code ready for the typed FreeRDP adapter boundary.
struct RDPSet1ScanCode: Equatable, Sendable, CustomStringConvertible {
    let value: UInt8
    let isExtended: Bool

    var description: String {
        String(format: "%@0x%02X", isExtended ? "E0 " : "", value)
    }
}

enum RDPScanCodeMappingError: Error, Equatable, CustomStringConvertible {
    case unsupportedHIDUsage(UInt16)

    var description: String {
        switch self {
        case let .unsupportedHIDUsage(usage):
            return String(format: "unsupported HID usage 0x%02X", usage)
        }
    }
}

enum RDPScanCodeMapper {
    /// Phase 0's mandatory Japanese-key mapping. Other usages are rejected
    /// until the production key map is introduced, rather than guessed.
    static func set1ScanCode(forHIDUsage usage: UInt16) throws -> RDPSet1ScanCode {
        switch usage {
        case HIDUsage.eisu:
            return RDPSet1ScanCode(value: 0x7B, isExtended: false)
        case HIDUsage.kana:
            return RDPSet1ScanCode(value: 0x79, isExtended: false)
        default:
            throw RDPScanCodeMappingError.unsupportedHIDUsage(usage)
        }
    }
}
