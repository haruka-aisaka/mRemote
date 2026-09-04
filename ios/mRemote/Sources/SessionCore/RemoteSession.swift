import Foundation

public enum SessionControlEvent: Sendable {
    case stateChanged(SessionState, generation: SessionGeneration)
    case userActionRequired(SessionChallenge)
    case error(RemoteSessionError)
}

public enum SessionVisibility: Hashable, Sendable {
    /// Presented and focused: input, audio and full presentation rate.
    case focused
    /// Connected but off screen. The connection and its channels keep running;
    /// presentation and transient decode buffers are reduced.
    case background
}

/// The protocol-independent part of a session: lifecycle, state and
/// challenges. A future SSH session implements exactly this much; desktop
/// frames, scan codes, audio and clipboard live in the capability protocols
/// below so that a terminal never has to model them.
public protocol RemoteSession: Actor {
    nonisolated var id: SessionID { get }
    nonisolated var profileID: ProfileID? { get }

    /// One stream per session. Ordered and finite-buffered: state and pending
    /// challenges stay authoritative on the session itself, so a consumer that
    /// misses events can always re-read rather than reconstruct.
    func controlEvents() -> AsyncStream<SessionControlEvent>

    var state: SessionState { get }
    var generation: SessionGeneration { get }

    func connect() async throws
    func disconnect(reason: DisconnectReason) async
    func respond(to challengeID: ChallengeID, with response: ChallengeResponse) async throws
    func setVisibility(_ visibility: SessionVisibility) async
}

/// Raised when a challenge is answered twice, or answered after the attempt it
/// belonged to has ended.
public struct StaleChallengeError: Error, Hashable, Sendable {
    public let challengeID: ChallengeID

    public init(challengeID: ChallengeID) {
        self.challengeID = challengeID
    }
}
