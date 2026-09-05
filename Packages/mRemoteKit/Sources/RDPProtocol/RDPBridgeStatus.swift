import Foundation
import SessionCore

/// The C bridge's `mr_rdp_status`, mirrored rather than imported.
///
/// This module is host-testable on purpose, and importing the bridge header
/// would tie it to an XCFramework that only exists once it has been built. The
/// values are part of the bridge ABI (`MR_RDP_BRIDGE_ABI_VERSION 1`), so they
/// are as stable as the header itself, and `RDPBridgeStatusABITests` fails if
/// the header and this enum ever disagree.
public enum RDPBridgeStatus: Int32, Hashable, Sendable, CaseIterable {
    case ok = 0
    case invalidArgument = -1
    case outOfMemory = -2
    case invalidState = -3
    case stopped = -4
    case timeout = -5
    case staleChallenge = -6
    case backendUnavailable = -7
    case backend = -8
    case invalidData = -9
    case limitExceeded = -10
    case certificateRejected = -11
    case unsupported = -12

    public var name: String {
        switch self {
        case .ok: return "MR_RDP_STATUS_OK"
        case .invalidArgument: return "MR_RDP_ERROR_INVALID_ARGUMENT"
        case .outOfMemory: return "MR_RDP_ERROR_OUT_OF_MEMORY"
        case .invalidState: return "MR_RDP_ERROR_INVALID_STATE"
        case .stopped: return "MR_RDP_ERROR_STOPPED"
        case .timeout: return "MR_RDP_ERROR_TIMEOUT"
        case .staleChallenge: return "MR_RDP_ERROR_STALE_CHALLENGE"
        case .backendUnavailable: return "MR_RDP_ERROR_BACKEND_UNAVAILABLE"
        case .backend: return "MR_RDP_ERROR_BACKEND"
        case .invalidData: return "MR_RDP_ERROR_INVALID_DATA"
        case .limitExceeded: return "MR_RDP_ERROR_LIMIT_EXCEEDED"
        case .certificateRejected: return "MR_RDP_ERROR_CERTIFICATE_REJECTED"
        case .unsupported: return "MR_RDP_ERROR_UNSUPPORTED"
        }
    }
}

/// The C bridge's `mr_rdp_session_state`.
public enum RDPBridgePhase: UInt32, Hashable, Sendable, CaseIterable {
    case created = 0
    case connecting = 1
    case awaitingCertificate = 2
    case connected = 3
    case stopping = 4
    case stopped = 5
    case failed = 6

    /// The `SessionState` this phase means, or nil where the session's own
    /// state machine is the authority. `stopped` is deliberately absent: the
    /// session reaches `disconnected` when its worker joins, not when the
    /// backend says it is done, so that nothing observes a terminal state
    /// while native memory is still being released.
    public var sessionState: SessionState? {
        switch self {
        case .created: return nil
        case .connecting: return .connecting
        case .awaitingCertificate: return .awaitingUser
        case .connected: return .connected
        case .stopping: return .disconnecting
        case .stopped: return nil
        case .failed: return .failed
        }
    }
}

/// The C bridge's `mr_rdp_channel_kind`. Only `disp` changes app behaviour in
/// Phase 2 - it is what makes a dynamic resolution request meaningful - but
/// the others are carried so a channel that fails to negotiate is visible in
/// a diagnostic rather than silently absent.
public enum RDPBridgeChannel: UInt8, Hashable, Sendable, CaseIterable {
    case cliprdr = 1
    case rdpsnd = 2
    case drdynvc = 3
    case disp = 4
    case rdpgfx = 5

    public var name: String {
        switch self {
        case .cliprdr: return "cliprdr"
        case .rdpsnd: return "rdpsnd"
        case .drdynvc: return "drdynvc"
        case .disp: return "disp"
        case .rdpgfx: return "rdpgfx"
        }
    }
}

/// How a connection attempt ended.
///
/// A server that logs the user off is not a failure, and showing it as one
/// would put a red error on the screen every time somebody signs out of
/// Windows. Only `failed` reaches the user as an error.
public enum RDPTerminationCause: Hashable, Sendable {
    /// This side asked for the stop.
    case stoppedLocally
    /// The server, or an administrator, ended the session deliberately.
    case remoteInitiated(detail: String)
    case failed(RemoteSessionError)

    public var error: RemoteSessionError? {
        guard case .failed(let error) = self else { return nil }
        return error
    }
}

/// Turns the bridge's status plus FreeRDP's own error code into the stable
/// categories the UI explains.
///
/// docs/architecture.md section 11 forbids showing a raw FreeRDP error, and
/// the categories exist so that a message can be written once per cause rather
/// than once per code. The FreeRDP codes are reproduced from
/// `freerdp/error.h` at the pinned 3.31.1; the class lives in the high 16 bits
/// and the type in the low 16.
public enum RDPErrorMapper {
    public static let connectErrorClass: UInt32 = 2
    public static let errorInfoClass: UInt32 = 1

    public static func classify(
        status: RDPBridgeStatus,
        nativeCode: Int32 = 0
    ) -> RDPTerminationCause {
        switch status {
        case .ok:
            return .stoppedLocally
        case .stopped:
            return .stoppedLocally
        case .certificateRejected:
            return .failed(.certificateRejected)
        case .timeout:
            return .failed(.connectionTimedOut)
        case .outOfMemory, .limitExceeded:
            return .failed(.resourceUnavailable)
        case .backendUnavailable:
            // The app was built without the generated bridge, or against a
            // slice that has no adapter. That is a build problem, not
            // something the user did.
            return .failed(.internalFailure(detail: "rdp backend unavailable"))
        case .invalidArgument, .invalidState, .staleChallenge:
            return .failed(.internalFailure(detail: status.name))
        case .invalidData:
            return .failed(.protocolFailure(detail: "invalid data from the server"))
        case .unsupported:
            return .failed(.protocolFailure(detail: "unsupported by this build"))
        case .backend:
            return classifyNative(nativeCode)
        }
    }

    /// FreeRDP's `freerdp_get_last_error`. Zero means the backend failed
    /// without recording a reason, which is worth reporting as such rather
    /// than guessing at a category.
    public static func classifyNative(_ nativeCode: Int32) -> RDPTerminationCause {
        let code = UInt32(bitPattern: nativeCode)
        guard code != 0 else {
            return .failed(.protocolFailure(detail: "backend failure with no reported cause"))
        }
        let errorClass = (code >> 16) & 0xFFFF
        let type = code & 0xFFFF

        switch errorClass {
        case connectErrorClass:
            return connectFailure(type: type)
        case errorInfoClass:
            return serverDisconnect(type: type)
        default:
            return .failed(.protocolFailure(
                detail: String(format: "freerdp 0x%08X", code)
            ))
        }
    }

    private static func connectFailure(type: UInt32) -> RDPTerminationCause {
        switch type {
        case 0x04, 0x05:
            // ERRCONNECT_DNS_ERROR, ERRCONNECT_DNS_NAME_NOT_FOUND
            return .failed(.nameResolutionFailed)
        case 0x06, 0x0D:
            // ERRCONNECT_CONNECT_FAILED, ERRCONNECT_CONNECT_TRANSPORT_FAILED
            return .failed(.connectionRefused)
        case 0x08, 0x0C, 0x1E:
            // ERRCONNECT_TLS_CONNECT_FAILED,
            // ERRCONNECT_SECURITY_NEGO_CONNECT_FAILED,
            // ERRCONNECT_HYBRID_REQUIRED_BY_SERVER
            return .failed(.tlsHandshakeFailed)
        case 0x09, 0x0E, 0x0F, 0x13, 0x14, 0x15, 0x16, 0x1B:
            // Authentication proper: the password is wrong, expired, or was
            // never supplied. Deliberately separate from the account states
            // below, because retrying one of those is what locks an account.
            return .failed(.authenticationFailed)
        case 0x0A, 0x10, 0x11, 0x12, 0x17, 0x18, 0x19, 0x1A:
            // Privileges, revocation, KDC, disabled/restricted/locked/expired
            // account, logon type not granted.
            return .failed(.accountRestricted)
        case 0x0B:
            // ERRCONNECT_CONNECT_CANCELLED
            return .stoppedLocally
        case 0x1C, 0x1D:
            // ERRCONNECT_ACTIVATION_TIMEOUT, ERRCONNECT_TARGET_BOOTING
            return .failed(.connectionTimedOut)
        default:
            return .failed(.protocolFailure(
                detail: String(format: "freerdp connect 0x%04X", type)
            ))
        }
    }

    private static func serverDisconnect(type: UInt32) -> RDPTerminationCause {
        switch type {
        case 0x01, 0x02, 0x0B, 0x0C:
            return .remoteInitiated(detail: "the server ended the session")
        case 0x03:
            return .remoteInitiated(detail: "the server disconnected an idle session")
        case 0x04:
            return .remoteInitiated(detail: "the sign-in took too long")
        case 0x05:
            return .remoteInitiated(detail: "another connection took over the session")
        case 0x06:
            return .failed(.resourceUnavailable)
        case 0x07, 0x09, 0x0A:
            return .failed(.accountRestricted)
        case 0x0100...0x010A:
            // Licensing. Not something a retry fixes, and not the user's
            // credentials either.
            return .failed(.accountRestricted)
        default:
            return .failed(.protocolFailure(
                detail: String(format: "freerdp errinfo 0x%04X", type)
            ))
        }
    }
}
