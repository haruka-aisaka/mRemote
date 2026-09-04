import Darwin
import Foundation

enum RDPConnectionField: String, Equatable, Sendable {
    case hostname
    case port
    case domain
    case username
    case password
}

enum RDPDiagnosticRedaction {
    static func endpoint(port: UInt16) -> String {
        "endpoint=<redacted>:\(port)"
    }
}

enum RDPConnectionValidationError: Error, Equatable, CustomStringConvertible {
    case required(RDPConnectionField)
    case containsNull(RDPConnectionField)
    case tooLong(RDPConnectionField, maximumUTF8Bytes: Int)
    case invalidPort

    var description: String {
        switch self {
        case let .required(field):
            return "\(field.rawValue) is required"
        case let .containsNull(field):
            return "\(field.rawValue) contains an unsupported null character"
        case let .tooLong(field, maximum):
            return "\(field.rawValue) exceeds \(maximum) UTF-8 bytes"
        case .invalidPort:
            return "port must be a number from 1 through 65535"
        }
    }
}

/// Values required for connection setup. Textual representations redact the
/// endpoint and account because diagnostics can be exported off-device.
struct RDPConnectionDescriptor: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    let hostname: String
    let port: UInt16
    let domain: String
    let username: String

    var description: String {
        "\(RDPDiagnosticRedaction.endpoint(port: port)) account=<redacted>"
    }

    var debugDescription: String { description }
}

/// A short-lived password container. Its textual representations are always
/// redacted and `clear()` overwrites the app-owned UTF-8 storage.
///
/// UIKit and Swift may make transient copies while accepting text, so this is
/// not a general-purpose secure-memory primitive. Its purpose here is to keep
/// the password out of model descriptions, the event journal, and exports.
final class RDPConnectionSecret: @unchecked Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    private let lock = NSLock()
    private var utf8: [UInt8]

    init(_ value: String) {
        utf8 = Array(value.utf8)
    }

    var description: String { "<redacted>" }
    var debugDescription: String { "<redacted>" }

    var isCleared: Bool {
        lock.withLock { utf8.isEmpty }
    }

    func withNullTerminatedUTF8<Result>(
        _ body: (UnsafePointer<CChar>) throws -> Result
    ) rethrows -> Result {
        try withUTF8Span { pointer, _ in try body(pointer) }
    }

    func withUTF8Span<Result>(
        _ body: (UnsafePointer<CChar>, Int) throws -> Result
    ) rethrows -> Result {
        try lock.withLock {
            var copy = utf8
            let count = copy.count
            copy.append(0)
            defer {
                Self.securelyClear(&copy)
            }
            return try copy.withUnsafeBytes { rawBuffer in
                let pointer = rawBuffer.bindMemory(to: CChar.self).baseAddress!
                return try body(pointer, count)
            }
        }
    }

    func clear() {
        lock.withLock {
            Self.securelyClear(&utf8)
            utf8.removeAll(keepingCapacity: false)
        }
    }

    deinit {
        clear()
    }

    private static func securelyClear(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress, !buffer.isEmpty else { return }
            _ = memset_s(baseAddress, buffer.count, 0, buffer.count)
        }
    }
}

struct ValidatedRDPConnection: CustomStringConvertible, CustomDebugStringConvertible {
    let descriptor: RDPConnectionDescriptor
    let password: RDPConnectionSecret

    var description: String {
        "\(descriptor) password=<redacted>"
    }

    var debugDescription: String { description }
}

struct RDPConnectionForm: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible {
    var hostname: String
    var port: String
    var domain: String
    var username: String
    var password: String

    var description: String {
        "endpoint=<redacted> account=<redacted> password=<redacted>"
    }

    var debugDescription: String { description }

    func validated() throws -> ValidatedRDPConnection {
        let hostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !hostname.isEmpty else {
            throw RDPConnectionValidationError.required(.hostname)
        }
        guard !username.isEmpty else {
            throw RDPConnectionValidationError.required(.username)
        }
        guard !password.isEmpty else {
            throw RDPConnectionValidationError.required(.password)
        }

        let values: [(RDPConnectionField, String)] = [
            (.hostname, hostname),
            (.port, port),
            (.domain, domain),
            (.username, username),
            (.password, password),
        ]
        if let invalid = values.first(where: { $0.1.contains("\0") }) {
            throw RDPConnectionValidationError.containsNull(invalid.0)
        }
        let limits: [(RDPConnectionField, String, Int)] = [
            (.hostname, hostname, 253),
            (.username, username, 1_024),
            (.domain, domain, 1_024),
            (.password, password, 4_096),
        ]
        if let invalid = limits.first(where: { $0.1.utf8.count > $0.2 }) {
            throw RDPConnectionValidationError.tooLong(
                invalid.0,
                maximumUTF8Bytes: invalid.2
            )
        }
        guard let parsedPort = UInt16(port), parsedPort > 0 else {
            throw RDPConnectionValidationError.invalidPort
        }

        return ValidatedRDPConnection(
            descriptor: RDPConnectionDescriptor(
                hostname: hostname,
                port: parsedPort,
                domain: domain,
                username: username
            ),
            password: RDPConnectionSecret(password)
        )
    }
}

enum HarnessSessionPhase: String, Equatable, Sendable {
    case idle
    case connecting
    case awaitingCertificate
    case connected
    case stopping
    case stopped
    case failed
}

struct HarnessSessionStatus: Equatable, Sendable, CustomStringConvertible {
    let generation: UInt64
    let phase: HarnessSessionPhase
    let statusCode: Int32?
    /// The backend's own failure detail, which distinguishes causes that all
    /// arrive as a single bridge status. Zero means the backend reported none.
    var nativeCode: Int32 = 0

    var description: String {
        guard let statusCode else {
            return "session g=\(generation) \(phase.rawValue)"
        }
        let detail = nativeCode == 0
            ? ""
            : " native=\(FreeRDPErrorCode.describe(nativeCode))"
        return "session g=\(generation) \(phase.rawValue) status=\(statusCode)\(detail)"
    }
}

/// Decodes `freerdp_get_last_error` values, which pack a class in the high 16
/// bits and a type in the low 16. Names follow the pinned FreeRDP 3.31.1
/// `freerdp/error.h`; the connect class is the one a failed `freerdp_connect`
/// reports, so it is the only class named here.
enum FreeRDPErrorCode {
    static func describe(_ code: Int32) -> String {
        let raw = UInt32(bitPattern: code)
        let errorClass = (raw >> 16) & 0xFFFF
        let type = raw & 0xFFFF
        let hex = String(format: "0x%08X", raw)
        guard errorClass == connectClass, let name = connectTypeNames[type] else {
            return String(format: "%@ class=0x%04X type=0x%04X", hex, errorClass, type)
        }
        return "\(hex) CONNECT/\(name)"
    }

    private static let connectClass: UInt32 = 2

    private static let connectTypeNames: [UInt32: String] = [
        0x01: "PRE_CONNECT_FAILED",
        0x02: "CONNECT_UNDEFINED",
        0x03: "POST_CONNECT_FAILED",
        0x04: "DNS_ERROR",
        0x05: "DNS_NAME_NOT_FOUND",
        0x06: "CONNECT_FAILED",
        0x07: "MCS_CONNECT_INITIAL_ERROR",
        0x08: "TLS_CONNECT_FAILED",
        0x09: "AUTHENTICATION_FAILED",
        0x0A: "INSUFFICIENT_PRIVILEGES",
        0x0B: "CONNECT_CANCELLED",
        0x0C: "SECURITY_NEGO_CONNECT_FAILED",
        0x0D: "CONNECT_TRANSPORT_FAILED",
        0x0E: "PASSWORD_EXPIRED",
        0x0F: "PASSWORD_CERTAINLY_EXPIRED",
        0x10: "CLIENT_REVOKED",
        0x11: "KDC_UNREACHABLE",
        0x12: "ACCOUNT_DISABLED",
        0x13: "PASSWORD_MUST_CHANGE",
        0x14: "LOGON_FAILURE",
        0x15: "WRONG_PASSWORD",
        0x16: "ACCESS_DENIED",
        0x17: "ACCOUNT_RESTRICTION",
        0x18: "ACCOUNT_LOCKED_OUT",
        0x19: "ACCOUNT_EXPIRED",
        0x1A: "LOGON_TYPE_NOT_GRANTED",
        0x1B: "NO_OR_MISSING_CREDENTIALS",
        0x1C: "ACTIVATION_TIMEOUT",
        0x1D: "TARGET_BOOTING",
        0x1E: "HYBRID_REQUIRED_BY_SERVER",
    ]
}

enum Phase0RDPChannel: Int, CaseIterable, Equatable, Hashable, Sendable {
    case cliprdr = 1
    case rdpsnd = 2
    case drdynvc = 3
    case disp = 4
    case rdpgfx = 5

    var diagnosticName: String {
        switch self {
        case .cliprdr: "cliprdr"
        case .rdpsnd: "rdpsnd"
        case .drdynvc: "drdynvc"
        case .disp: "disp"
        case .rdpgfx: "rdpgfx"
        }
    }
}

enum Phase0ChannelTransition: Int, Equatable, Sendable {
    case disconnected = 0
    case connected = 1
}

enum Phase0ClipboardProbeStage: Int, CaseIterable, Equatable, Hashable, Sendable {
    case formatListSent = 1
    case formatListResponse = 2
    case dataRequest = 3
    case dataResponseSent = 4

    var diagnosticName: String {
        switch self {
        case .formatListSent: "format-list-sent"
        case .formatListResponse: "format-list-response"
        case .dataRequest: "data-request"
        case .dataResponseSent: "data-response-sent"
        }
    }
}

struct Phase0ChannelTelemetry: Equatable, Sendable, CustomStringConvertible {
    let generation: UInt64
    let sequence: UInt64
    let channel: Phase0RDPChannel
    let transition: Phase0ChannelTransition

    var description: String {
        "channel g=\(generation) seq=\(sequence) \(channel.diagnosticName) \(transition == .connected ? "connected" : "disconnected")"
    }
}

/// Deliberately has no clipboard-content property. Native code constructs this
/// only from the bridge's count/hash telemetry, so descriptions and exports
/// cannot accidentally include the probe body.
struct Phase0ClipboardProbeTelemetry: Equatable, Sendable, CustomStringConvertible {
    let generation: UInt64
    let sequence: UInt64
    let probeID: UInt64
    let stage: Phase0ClipboardProbeStage
    let payloadByteCount: Int
    let payloadSHA256: String
    let statusCode: Int32

    var description: String {
        "cliprdr-probe g=\(generation) seq=\(sequence) id=\(probeID) stage=\(stage.diagnosticName) bytes=\(payloadByteCount) SHA256=\(payloadSHA256) status=\(statusCode)"
    }
}

struct Phase0DisplayResizeTelemetry: Equatable, Sendable, CustomStringConvertible {
    let generation: UInt64
    let sequence: UInt64
    let requestID: UInt64
    let width: UInt32
    let height: UInt32
    let statusCode: Int32

    var description: String {
        "disp-resize g=\(generation) seq=\(sequence) id=\(requestID) size=\(width)x\(height) status=\(statusCode)"
    }
}

struct Phase0ChannelExerciseCounters: Equatable, Sendable {
    let generation: UInt64
    private(set) var lastSequence: UInt64 = 0
    private(set) var connectedCounts: [Phase0RDPChannel: Int] = [:]
    private(set) var disconnectedCounts: [Phase0RDPChannel: Int] = [:]
    private(set) var currentChannelState: [Phase0RDPChannel: Bool] = [:]
    private(set) var clipboardStageCounts: [Phase0ClipboardProbeStage: Int] = [:]
    private(set) var clipboardFailureCount = 0
    private(set) var displayResizeSuccessCount = 0
    private(set) var displayResizeFailureCount = 0

    mutating func record(_ telemetry: Phase0ChannelTelemetry) -> Bool {
        guard accept(generation: telemetry.generation, sequence: telemetry.sequence) else {
            return false
        }
        switch telemetry.transition {
        case .connected:
            connectedCounts[telemetry.channel, default: 0] += 1
            currentChannelState[telemetry.channel] = true
        case .disconnected:
            disconnectedCounts[telemetry.channel, default: 0] += 1
            currentChannelState[telemetry.channel] = false
        }
        return true
    }

    mutating func record(_ telemetry: Phase0ClipboardProbeTelemetry) -> Bool {
        guard accept(generation: telemetry.generation, sequence: telemetry.sequence) else {
            return false
        }
        clipboardStageCounts[telemetry.stage, default: 0] += 1
        if telemetry.statusCode != 0 { clipboardFailureCount += 1 }
        return true
    }

    mutating func record(_ telemetry: Phase0DisplayResizeTelemetry) -> Bool {
        guard accept(generation: telemetry.generation, sequence: telemetry.sequence) else {
            return false
        }
        if telemetry.statusCode == 0 {
            displayResizeSuccessCount += 1
        } else {
            displayResizeFailureCount += 1
        }
        return true
    }

    func isConnected(_ channel: Phase0RDPChannel) -> Bool {
        currentChannelState[channel] ?? false
    }

    var summary: String {
        let channels = Phase0RDPChannel.allCases.map { channel in
            let connected = connectedCounts[channel, default: 0]
            let disconnected = disconnectedCounts[channel, default: 0]
            let state = isConnected(channel) ? "up" : "down"
            return "\(channel.diagnosticName)=\(connected)/\(disconnected):\(state)"
        }.joined(separator: " ")
        let clipboard = Phase0ClipboardProbeStage.allCases.map {
            "\($0.diagnosticName)=\(clipboardStageCounts[$0, default: 0])"
        }.joined(separator: " ")
        return "\(channels)\nclip \(clipboard) fail=\(clipboardFailureCount)  disp ok=\(displayResizeSuccessCount) fail=\(displayResizeFailureCount)"
    }

    private mutating func accept(generation: UInt64, sequence: UInt64) -> Bool {
        guard generation == self.generation, sequence > lastSequence else { return false }
        lastSequence = sequence
        return true
    }
}

/// Stable router target used to atomically switch the harness from recording
/// to native session input without rebuilding the UIKit/GC arbiters.
@MainActor
final class SwitchingInputSink: HarnessInputSink {
    private let recordingSink: HarnessInputSink
    private var sessionSink: HarnessInputSink?

    init(recordingSink: HarnessInputSink) {
        self.recordingSink = recordingSink
    }

    func useSessionSink(_ sink: HarnessInputSink) {
        sessionSink = sink
    }

    func useRecordingSink() {
        sessionSink = nil
    }

    func enqueue(_ input: OutboundInput, generation: UInt64) {
        (sessionSink ?? recordingSink).enqueue(input, generation: generation)
    }
}
