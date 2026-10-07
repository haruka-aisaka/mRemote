import XCTest
@testable import SessionCore

final class SessionStateMachineTests: XCTestCase {
    func testConnectPathReachesConnected() {
        var machine = SessionStateMachine()
        XCTAssertEqual(machine.transition(to: .connecting), .connecting)
        XCTAssertEqual(machine.transition(to: .connected), .connected)
        XCTAssertEqual(machine.generation, SessionGeneration(1))
    }

    func testAnsweringACertificateResumesTheSameAttempt() {
        var machine = SessionStateMachine()
        machine.transition(to: .connecting)
        let attempt = machine.generation
        machine.transition(to: .awaitingUser)
        XCTAssertEqual(machine.resumeAttempt(), .connecting)
        XCTAssertEqual(machine.generation, attempt, "the attempt's own events must still apply")
        XCTAssertEqual(machine.transition(to: .connected), .connected)
    }

    func testResumingIsOnlyFromAwaitingUser() {
        var machine = SessionStateMachine()
        XCTAssertNil(machine.resumeAttempt())
        machine.transition(to: .connecting)
        XCTAssertNil(machine.resumeAttempt())
        XCTAssertEqual(machine.state, .connecting)
    }

    func testAnsweringWithCredentialsStartsANewAttempt() {
        var machine = SessionStateMachine()
        machine.transition(to: .connecting)
        let attempt = machine.generation
        machine.transition(to: .awaitingUser)
        machine.transition(to: .connecting)
        XCTAssertGreaterThan(machine.generation, attempt)
    }

    func testDisconnectedIsOnlyReachableThroughDisconnecting() {
        var machine = SessionStateMachine()
        machine.transition(to: .connecting)
        machine.transition(to: .connected)
        XCTAssertNil(machine.transition(to: .disconnected))
        XCTAssertEqual(machine.state, .connected)
        machine.transition(to: .disconnecting)
        XCTAssertEqual(machine.transition(to: .disconnected), .disconnected)
    }

    func testALiveConnectionCanFailAndBeRetried() {
        var machine = SessionStateMachine()
        machine.transition(to: .connecting)
        machine.transition(to: .connected)
        let generation = machine.generation
        XCTAssertEqual(machine.transition(to: .failed), .failed)
        XCTAssertEqual(machine.transition(to: .connecting), .connecting)
        XCTAssertGreaterThan(machine.generation, generation)
    }

    func testDisconnectedIsTerminal() {
        var machine = SessionStateMachine(state: .disconnected)
        for state in [SessionState.idle, .connecting, .connected, .failed, .disconnecting] {
            XCTAssertNil(machine.transition(to: state), "\(state) must not follow disconnected")
        }
    }

    func testRetryAfterFailureAdvancesGeneration() {
        var machine = SessionStateMachine()
        machine.transition(to: .connecting)
        machine.transition(to: .failed)
        machine.transition(to: .connecting)
        XCTAssertEqual(machine.generation, SessionGeneration(2))
    }

    func testFirstConnectDoesNotAdvanceGeneration() {
        var machine = SessionStateMachine()
        machine.transition(to: .connecting)
        XCTAssertEqual(machine.generation, SessionGeneration(1))
    }

    func testChallengeRoundTripAdvancesGeneration() {
        var machine = SessionStateMachine()
        machine.transition(to: .connecting)
        machine.transition(to: .awaitingUser)
        machine.transition(to: .connecting)
        XCTAssertEqual(machine.generation, SessionGeneration(2))
    }

    func testConnectedDoesNotRestartItself() {
        var machine = SessionStateMachine()
        machine.transition(to: .connecting)
        machine.transition(to: .connected)
        XCTAssertNil(machine.transition(to: .connecting))
    }

    func testActiveAndInputPredicates() {
        XCTAssertTrue(SessionState.connecting.isActive)
        XCTAssertTrue(SessionState.disconnecting.isActive)
        XCTAssertFalse(SessionState.failed.isActive)
        XCTAssertFalse(SessionState.disconnected.isActive)
        XCTAssertTrue(SessionState.connected.acceptsInput)
        XCTAssertFalse(SessionState.reconnecting.acceptsInput)
    }
}
