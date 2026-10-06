import Foundation

/// The lifecycle of one session, as drawn in docs/architecture.md section 7.1.
public enum SessionState: Hashable, Sendable, Codable {
    case idle
    case connecting
    /// Blocked on the user: a credential prompt or a certificate review.
    case awaitingUser
    case connected
    /// A recoverable network loss is being retried without user action.
    case reconnecting
    case disconnecting
    case disconnected
    case failed

    public var isTerminal: Bool { self == .disconnected }

    /// True while the session holds native resources worth counting against a
    /// connection budget.
    public var isActive: Bool {
        switch self {
        case .connecting, .awaitingUser, .connected, .reconnecting, .disconnecting:
            return true
        case .idle, .disconnected, .failed:
            return false
        }
    }

    /// True when input may be delivered to the remote host.
    public var acceptsInput: Bool { self == .connected }
}

/// Serialises state changes for one session.
///
/// The transition table is explicit rather than implied by the call sites,
/// because the states that look harmless to skip are exactly the ones that
/// leak resources: reaching `disconnected` without passing through
/// `disconnecting` would mean nothing waited for the native teardown, and
/// re-entering `connecting` from `connected` would start a second attempt on
/// top of a live one.
public struct SessionStateMachine: Sendable {
    public private(set) var state: SessionState
    public private(set) var generation: SessionGeneration

    public init(state: SessionState = .idle, generation: SessionGeneration = SessionGeneration()) {
        self.state = state
        self.generation = generation
    }

    private static let allowed: [SessionState: Set<SessionState>] = [
        .idle: [.connecting],
        .connecting: [.awaitingUser, .connected, .failed, .disconnecting],
        .awaitingUser: [.connecting, .disconnecting, .failed],
        // A live connection can fail outright: the network goes, the server
        // drops the socket. Without this edge the state stayed `connected`
        // after the worker had already ended, and nothing could retry it.
        .connected: [.reconnecting, .disconnecting, .failed],
        .reconnecting: [.connected, .failed, .disconnecting],
        .disconnecting: [.disconnected],
        .failed: [.connecting, .disconnecting],
        .disconnected: [],
    ]

    public func canTransition(to next: SessionState) -> Bool {
        Self.allowed[state, default: []].contains(next)
    }

    /// Applies a transition, or returns nil when it is not part of the state
    /// machine. A refused transition is a programming error at the call site,
    /// but it is reported rather than trapped so a late native callback cannot
    /// crash the app.
    @discardableResult
    public mutating func transition(to next: SessionState) -> SessionState? {
        guard canTransition(to: next) else { return nil }
        // A retry is a new connection attempt: everything issued under the old
        // generation - queued input, an unanswered challenge, an in-flight
        // native callback - must stop applying at this point.
        if next == .connecting, state != .idle {
            generation = generation.next
        }
        state = next
        return next
    }
}
