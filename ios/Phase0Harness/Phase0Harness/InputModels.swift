import CoreGraphics
import Foundation

enum KeyboardEventSource: String, CaseIterable {
    case uiKit = "UIKit"
    case gameController = "GCKeyboard"
}

enum PointerEventSource: String, CaseIterable {
    case uiKit = "UIKit pointer"
    case gameController = "GCMouse"
}

enum KeyTransition: String {
    case down
    case up
    case cancel
}

struct HardwareKeyEvent: Equatable {
    let usage: UInt16
    let transition: KeyTransition
    let source: KeyboardEventSource
    let uptime: TimeInterval
}

enum PointerButton: String, Hashable, CaseIterable {
    case left
    case right
    case middle
}

enum PointerPayload: Equatable {
    case move(remote: CGPoint)
    case button(PointerButton, KeyTransition, remote: CGPoint?)
    case scroll(horizontal: Double, vertical: Double)
}

struct PointerInputEvent: Equatable {
    let payload: PointerPayload
    let source: PointerEventSource
    let uptime: TimeInterval
}

enum OutboundInput: Equatable {
    case hardwareKey(usage: UInt16, transition: KeyTransition)
    case pointer(PointerPayload)
    case hostASCII(String)
    case committedText(String)
}

@MainActor
protocol HarnessInputSink: AnyObject {
    func enqueue(_ input: OutboundInput, generation: UInt64)
}

enum HIDUsage {
    static let kana: UInt16 = 0x90
    static let eisu: UInt16 = 0x91

    /// Release diagnostics may retain event-level details only for this
    /// explicit non-printing allow-list. Other usages can reconstruct typed
    /// content even when no character string is recorded.
    static func isReleaseDiagnosticAllowListed(_ usage: UInt16) -> Bool {
        usage == kana || usage == eisu
    }

    static func name(_ usage: UInt16) -> String {
        switch usage {
        case kana: return "LANG1/Kana"
        case eisu: return "LANG2/Eisu"
        case 0x04...0x1D:
            let scalar = UnicodeScalar(Int(usage - 0x04) + 65)
            return scalar.map { "Keyboard\(Character($0))" } ?? "Keyboard letter"
        case 0x28: return "Return"
        case 0x29: return "Escape"
        case 0x2A: return "Backspace"
        case 0x2B: return "Tab"
        case 0x2C: return "Space"
        case 0x4F: return "Right Arrow"
        case 0x50: return "Left Arrow"
        case 0x51: return "Down Arrow"
        case 0x52: return "Up Arrow"
        case 0x87: return "International1/Ro"
        case 0x88: return "International2/Kana"
        case 0x89: return "International3/Yen"
        case 0x8A: return "International4/Convert"
        case 0x8B: return "International5/NonConvert"
        case 0x94: return "LANG5/Zenkaku"
        case 0xE0: return "Left Control"
        case 0xE1: return "Left Shift"
        case 0xE2: return "Left Alt"
        case 0xE3: return "Left GUI"
        case 0xE4: return "Right Control"
        case 0xE5: return "Right Shift"
        case 0xE6: return "Right Alt"
        case 0xE7: return "Right GUI"
        default: return "usage"
        }
    }
}

extension OutboundInput {
    var diagnosticDescription: String {
        switch self {
        case let .hardwareKey(usage, transition):
            guard HIDUsage.isReleaseDiagnosticAllowListed(usage) else {
                return "hardware key details redacted"
            }
            if let scanCode = try? RDPScanCodeMapper.set1ScanCode(forHIDUsage: usage) {
                return String(
                    format: "key %@ HID=0x%02X set1=%@ %@",
                    HIDUsage.name(usage), usage, scanCode.description, transition.rawValue
                )
            }
            return String(
                format: "key %@ HID=0x%02X set1=unsupported %@",
                HIDUsage.name(usage), usage, transition.rawValue
            )
        case let .pointer(payload):
            return payload.diagnosticDescription
        case let .hostASCII(text):
            return "host ASCII UTF8=\(text.utf8.count)"
        case let .committedText(text):
            return "text UTF16=\(text.utf16.count) UTF8=\(text.utf8.count)"
        }
    }
}

extension PointerPayload {
    var diagnosticDescription: String {
        switch self {
        case let .move(remote):
            return String(format: "pointer move %.1f,%.1f", remote.x, remote.y)
        case let .button(button, transition, remote):
            if let remote {
                return String(
                    format: "pointer %@ %@ @ %.1f,%.1f",
                    button.rawValue, transition.rawValue, remote.x, remote.y
                )
            }
            return "pointer \(button.rawValue) \(transition.rawValue)"
        case let .scroll(horizontal, vertical):
            return String(format: "pointer scroll h=%.2f v=%.2f", horizontal, vertical)
        }
    }
}
