import XCTest
import AppleAdapters
import Persistence
import SessionCore
@testable import mRemote

/// Phase 4 against `FakeRemoteSession`: focus moves with the presented
/// session, an ordinary tap returns to a running session, and a dropped
/// connection is retried by policy.
@MainActor
final class MultiSessionTests: XCTestCase {
    private func makeEnvironment() async -> AppEnvironment {
        let environment = AppEnvironment(
            store: InMemoryProfileStore(),
            credentials: InMemoryCredentialRepository(),
            trust: InMemoryTrustRepository(),
            factories: SessionFactoryRegistry(factories: [FakeSessionFactory()])
        )
        await environment.start()
        for name in ["office", "lab"] {
            await environment.save(ConnectionProfile(
                displayName: name,
                endpoint: RemoteEndpoint(host: "\(name).example", port: 3389)
            ), password: nil)
        }
        return environment
    }

    private func waitUntil(
        timeout: TimeInterval = 10,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testFocusFollowsTheSwitcherAndLeavesWithTheList() async throws {
        let environment = await makeEnvironment()
        let office = try XCTUnwrap(environment.profiles.first { $0.displayName == "office" })
        let lab = try XCTUnwrap(environment.profiles.first { $0.displayName == "lab" })

        await environment.connect(to: office)
        await environment.connect(to: lab)
        XCTAssertEqual(environment.runningSessions.count, 2)
        let officeModel = try XCTUnwrap(environment.runningSession(for: office))
        let labModel = try XCTUnwrap(environment.runningSession(for: lab))
        XCTAssertTrue(labModel.isFocused)
        XCTAssertFalse(officeModel.isFocused)
        // Only the focused session may take input.
        XCTAssertTrue(labModel.acceptsInput)
        XCTAssertFalse(officeModel.acceptsInput)

        environment.switchTo(officeModel)
        await waitUntil { officeModel.isFocused }
        XCTAssertEqual(environment.presentedSession?.id, officeModel.id)
        XCTAssertFalse(labModel.acceptsInput)

        officeModel.isMenuPresented = true
        XCTAssertFalse(officeModel.acceptsInput, "an open menu closes the gate")
        officeModel.isMenuPresented = false

        environment.returnToList()
        await waitUntil { environment.focusedSessionID == nil }
        XCTAssertNil(environment.presentedSession)
        XCTAssertEqual(environment.runningSessions.count, 2, "SES-02: nothing disconnects")
        let visibility = await (environment.sessions.session(for: officeModel.id) as? FakeRemoteSession)?
            .currentVisibility
        XCTAssertEqual(visibility, .background)
    }

    func testDisconnectingOneSessionLeavesTheOtherRunning() async throws {
        let environment = await makeEnvironment()
        for profile in environment.profiles {
            await environment.connect(to: profile)
        }
        let first = try XCTUnwrap(environment.runningSessions.first)
        await first.disconnect()
        XCTAssertEqual(environment.runningSessions.count, 1)
        XCTAssertEqual(environment.runningSessions.first?.state, .connected)
    }

    func testADroppedConnectionIsRetriedAutomatically() async throws {
        let environment = await makeEnvironment()
        let office = try XCTUnwrap(environment.profiles.first { $0.displayName == "office" })
        await environment.connect(to: office)
        let model = try XCTUnwrap(environment.runningSession(for: office))
        let found = await environment.sessions.session(for: model.id)
        let fake = try XCTUnwrap(found as? FakeRemoteSession)
        await waitUntil { model.state == .connected }

        await fake.simulateConnectionLoss(.networkUnreachable)
        await waitUntil { model.reconnectAttempt != nil }
        XCTAssertEqual(model.reconnectAttempt, 1)
        XCTAssertTrue(model.statusText.hasPrefix("再接続中"))

        // The first backoff is one second; the fake reconnects at once.
        await waitUntil(timeout: 5) { model.state == .connected }
        XCTAssertEqual(model.state, .connected)
        XCTAssertNil(model.reconnectAttempt)
    }

    func testAnAuthenticationFailureIsNotRetried() async throws {
        let environment = await makeEnvironment()
        let office = try XCTUnwrap(environment.profiles.first)
        await environment.connect(to: office)
        let model = try XCTUnwrap(environment.runningSession(for: office))
        let found = await environment.sessions.session(for: model.id)
        let fake = try XCTUnwrap(found as? FakeRemoteSession)
        await waitUntil { model.state == .connected }

        await fake.simulateConnectionLoss(.authenticationFailed)
        await waitUntil { model.state == .failed && model.lastError != nil }
        XCTAssertNil(model.reconnectAttempt)
        XCTAssertTrue(model.canRetry)
    }
}
