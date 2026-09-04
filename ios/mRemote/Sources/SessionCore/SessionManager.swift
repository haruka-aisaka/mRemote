import Foundation

/// The result of moving focus. The caller is expected to act on
/// `releasedSessionID` before delivering anything to `focusedSessionID`:
/// the old session's pressed keys and buttons must be cleared locally, and
/// their releases best-effort enqueued, before input can reach the new one.
public struct FocusChange: Hashable, Sendable {
    public let releasedSessionID: SessionID?
    public let focusedSessionID: SessionID?
}

/// Refused because the connection budget is already committed. The budget is
/// checked as a serial reservation rather than a read followed by a connect,
/// so two simultaneous connects cannot both pass a check-then-act test.
public struct SessionBudgetExceededError: Error, Hashable, Sendable {
    public let limit: Int
}

public struct DuplicateSessionError: Error, Hashable, Sendable {
    public let sessionID: SessionID
}

/// Owns the running sessions and which one has focus.
///
/// It stays on the control plane: state, focus and lifecycle. Frames, input,
/// audio and clipboard payloads never pass through here, because routing every
/// frame through one actor would serialise the whole app behind the busiest
/// session.
public actor SessionManager {
    private var sessions: [SessionID: any RemoteSession] = [:]
    private var order: [SessionID] = []
    private(set) public var focusedSessionID: SessionID?

    /// Two 1080p sessions are the requirement and three the goal; the real
    /// per-device number comes from measurement in Phase 4. Until then this is
    /// the reservation that keeps a fourth connect from being attempted.
    public let sessionLimit: Int

    public init(sessionLimit: Int = 3) {
        self.sessionLimit = sessionLimit
    }

    public var sessionIDs: [SessionID] { order }

    public var count: Int { sessions.count }

    public func session(for id: SessionID) -> (any RemoteSession)? { sessions[id] }

    public var focusedSession: (any RemoteSession)? {
        focusedSessionID.flatMap { sessions[$0] }
    }

    /// Sessions started from one profile, in start order. The same profile may
    /// legitimately be connected more than once.
    public func sessions(for profileID: ProfileID) -> [SessionID] {
        order.filter { sessions[$0]?.profileID == profileID }
    }

    /// Reserves a slot and takes ownership of the session. The session is
    /// added before it connects, so a slot cannot be handed out twice while an
    /// attempt is in flight.
    @discardableResult
    public func add(_ session: any RemoteSession, focus: Bool = true) throws -> FocusChange {
        guard sessions[session.id] == nil else {
            throw DuplicateSessionError(sessionID: session.id)
        }
        guard sessions.count < sessionLimit else {
            throw SessionBudgetExceededError(limit: sessionLimit)
        }
        sessions[session.id] = session
        order.append(session.id)
        guard focus else {
            return FocusChange(releasedSessionID: nil, focusedSessionID: focusedSessionID)
        }
        return setFocus(to: session.id)
    }

    @discardableResult
    public func setFocus(to id: SessionID?) -> FocusChange {
        if let id, sessions[id] == nil {
            return FocusChange(releasedSessionID: nil, focusedSessionID: focusedSessionID)
        }
        guard id != focusedSessionID else {
            return FocusChange(releasedSessionID: nil, focusedSessionID: focusedSessionID)
        }
        let previous = focusedSessionID
        focusedSessionID = id
        return FocusChange(releasedSessionID: previous, focusedSessionID: id)
    }

    /// Removes a session that has finished tearing down, releasing its slot.
    /// Focus moves to the most recently added remaining session so the user is
    /// never left looking at nothing while other sessions are still connected.
    @discardableResult
    public func remove(_ id: SessionID) -> FocusChange {
        guard sessions.removeValue(forKey: id) != nil else {
            return FocusChange(releasedSessionID: nil, focusedSessionID: focusedSessionID)
        }
        order.removeAll { $0 == id }
        guard focusedSessionID == id else {
            return FocusChange(releasedSessionID: nil, focusedSessionID: focusedSessionID)
        }
        focusedSessionID = nil
        return setFocus(to: order.last)
    }

    /// Disconnects everything, e.g. on scene teardown. Each session is asked
    /// once and in order; a session that is already stopping treats it as a
    /// no-op, because stop has to be idempotent on every exit path.
    public func disconnectAll(reason: DisconnectReason) async {
        for id in order {
            await sessions[id]?.disconnect(reason: reason)
        }
    }

    /// Tells every non-focused session to reduce presentation. Called on focus
    /// change and on a memory warning; it never disconnects a session, because
    /// memory pressure is not a reason to drop the user's connection.
    public func applyVisibilityPolicy() async {
        for id in order {
            let visibility: SessionVisibility = (id == focusedSessionID) ? .focused : .background
            await sessions[id]?.setVisibility(visibility)
        }
    }
}
