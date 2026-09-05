import Foundation

/// Serialises every call into one `mr_rdp_session` and blocks `destroy` until
/// the calls already inside it have returned.
///
/// The bridge header is explicit that raw-pointer lifetime stays with the
/// caller: it drains its own in-flight work, but it cannot stop a call that
/// has read the pointer and not yet entered the bridge. That gap is this
/// type's whole job, and it is the reason the session actor never holds the
/// pointer itself. docs/architecture.md section 5.2 orders the teardown -
/// closing flag, wake the waits, drain in flight, join, then free - and
/// `destroy` implements the last three of those on the Swift side.
final class RDPNativeCallGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var session: OpaquePointer?
    private var callsInFlight = 0
    private var stopRequested = false
    private var destroying = false

    /// Publishes the handle once `mr_rdp_session_create` has returned it. A
    /// stop that arrived before the handle existed is replayed here, so a
    /// disconnect racing the create cannot be lost and leave a worker running.
    func install(_ session: OpaquePointer) {
        condition.lock()
        precondition(self.session == nil && !destroying, "the gate takes one session")
        self.session = session
        let mustStop = stopRequested
        condition.unlock()
        if mustStop { _ = requestStop() }
    }

    var hasSession: Bool {
        condition.lock()
        defer { condition.unlock() }
        return session != nil
    }

    @discardableResult
    func requestStop() -> mr_rdp_status? {
        condition.lock()
        stopRequested = true
        condition.unlock()
        return call { mr_rdp_session_request_stop($0) }
    }

    func respondCertificate(
        generation: UInt64,
        challengeID: UInt64,
        decision: mr_rdp_certificate_decision
    ) -> mr_rdp_status? {
        call { mr_rdp_session_respond_certificate($0, generation, challengeID, decision) }
    }

    func cancelChallenge(generation: UInt64, challengeID: UInt64) -> mr_rdp_status? {
        call { mr_rdp_session_cancel_challenge($0, generation, challengeID) }
    }

    func sendKey(_ event: inout mr_rdp_key_event) -> mr_rdp_status? {
        call { mr_rdp_session_send_key($0, &event) }
    }

    func sendPointer(_ event: inout mr_rdp_pointer_event) -> mr_rdp_status? {
        call { mr_rdp_session_send_pointer($0, &event) }
    }

    func requestDisplayResize(_ request: inout mr_rdp_display_resize_request) -> mr_rdp_status? {
        call { mr_rdp_session_request_display_resize($0, &request) }
    }

    /// Closes the gate to new calls, waits for the ones already through it,
    /// then frees. Must not be called from the run or callback thread; the
    /// worker calls it only after `mr_rdp_session_run` has returned.
    @discardableResult
    func destroy() -> mr_rdp_status? {
        condition.lock()
        destroying = true
        while callsInFlight > 0 { condition.wait() }
        let doomed = session
        session = nil
        condition.unlock()
        guard let doomed else { return nil }
        return mr_rdp_session_destroy(doomed)
    }

    /// nil means the session is gone or going: the caller treats that as a
    /// dropped call rather than an error, because every exit path may race a
    /// teardown and stop has to stay idempotent.
    private func call(_ body: (OpaquePointer) -> mr_rdp_status) -> mr_rdp_status? {
        condition.lock()
        guard !destroying, let session else {
            condition.unlock()
            return nil
        }
        callsInFlight += 1
        condition.unlock()

        let result = body(session)

        condition.lock()
        callsInFlight -= 1
        condition.broadcast()
        condition.unlock()
        return result
    }
}
