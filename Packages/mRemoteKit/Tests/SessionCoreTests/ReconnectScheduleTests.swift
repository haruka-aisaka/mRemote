import XCTest
@testable import SessionCore

final class ReconnectScheduleTests: XCTestCase {
    private let schedule = ReconnectSchedule()

    func testANetworkDropAfterConnectingIsRetriedWithBackoff() {
        let delays = (1...3).map {
            schedule.delay(
                beforeAttempt: $0, after: .networkUnreachable,
                policy: .automatic, hadConnected: true
            )
        }
        XCTAssertEqual(delays, [.seconds(1), .seconds(2), .seconds(4)])
        XCTAssertNil(schedule.delay(
            beforeAttempt: 4, after: .networkUnreachable,
            policy: .automatic, hadConnected: true
        ))
    }

    func testNothingIsRetriedThatNeedsTheUser() {
        // Retrying a refused password is how an account gets locked out.
        XCTAssertNil(schedule.delay(
            beforeAttempt: 1, after: .authenticationFailed,
            policy: .automatic, hadConnected: true
        ))
        XCTAssertNil(schedule.delay(
            beforeAttempt: 1, after: nil, policy: .automatic, hadConnected: true
        ))
    }

    func testAFirstAttemptAndADisabledPolicyAreNeverRetried() {
        XCTAssertNil(schedule.delay(
            beforeAttempt: 1, after: .connectionTimedOut,
            policy: .automatic, hadConnected: false
        ))
        XCTAssertNil(schedule.delay(
            beforeAttempt: 1, after: .connectionTimedOut,
            policy: .disabled, hadConnected: true
        ))
    }
}
