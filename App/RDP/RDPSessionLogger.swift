import Foundation
import OSLog
import AppleAdapters
import SessionCore

/// The session's own log lines, already redacted.
///
/// docs/architecture.md section 11 bans the host name, the user name and the
/// framebuffer from the log, so the endpoint is only ever a stable digest and
/// nothing here takes a payload. It exists as a type rather than as calls to
/// `Logger` at each site so a line cannot be added later that forgets.
struct RDPSessionLogger: Sendable {
    private let sessionLog: Logger
    private let trustLog: Logger
    private let renderingLog: Logger
    private let endpointToken: String
    private let sessionToken: String

    init(sessionID: SessionID, endpoint: RemoteEndpoint) {
        sessionLog = AppLog.logger(.session)
        trustLog = AppLog.logger(.trust)
        renderingLog = AppLog.logger(.rendering)
        endpointToken = Redaction.endpoint(host: endpoint.host, port: endpoint.port)
        sessionToken = String(sessionID.rawValue.uuidString.prefix(8))
    }

    func session(_ message: String) {
        sessionLog.info("[\(sessionToken, privacy: .public)] \(endpointToken, privacy: .public) \(message, privacy: .public)")
    }

    func sessionError(_ message: String) {
        sessionLog.error("[\(sessionToken, privacy: .public)] \(endpointToken, privacy: .public) \(message, privacy: .public)")
    }

    func certificate(_ message: String) {
        trustLog.info("[\(sessionToken, privacy: .public)] \(endpointToken, privacy: .public) \(message, privacy: .public)")
    }

    func rendering(_ message: String) {
        renderingLog.debug("[\(sessionToken, privacy: .public)] \(message, privacy: .public)")
    }
}
