import XCTest
@testable import SessionCore

final class SessionManagerTests: XCTestCase {
    private func configuration(name: String) -> EffectiveConnectionConfiguration {
        EffectiveProfileResolver().resolve(
            profile: ConnectionProfile(
                displayName: name,
                endpoint: RemoteEndpoint(host: "\(name).example", port: 3389)
            ),
            globalSettings: .default
        )
    }

    func testAddFocusesTheNewSession() async throws {
        let manager = SessionManager()
        let first = FakeRemoteSession(configuration: configuration(name: "a"))
        let second = FakeRemoteSession(configuration: configuration(name: "b"))

        _ = try await manager.add(first)
        let change = try await manager.add(second)

        XCTAssertEqual(change.releasedSessionID, first.id)
        XCTAssertEqual(change.focusedSessionID, second.id)
        await AsyncAssertEqual(await manager.focusedSessionID, second.id)
    }

    func testBudgetIsReservedSerially() async throws {
        let manager = SessionManager(sessionLimit: 2)
        _ = try await manager.add(FakeRemoteSession(configuration: configuration(name: "a")))
        _ = try await manager.add(FakeRemoteSession(configuration: configuration(name: "b")))

        do {
            _ = try await manager.add(FakeRemoteSession(configuration: configuration(name: "c")))
            XCTFail("expected the third session to be refused")
        } catch let error as SessionBudgetExceededError {
            XCTAssertEqual(error.limit, 2)
        }
        await AsyncAssertEqual(await manager.count, 2)
    }

    func testRemovingTheFocusedSessionMovesFocus() async throws {
        let manager = SessionManager()
        let first = FakeRemoteSession(configuration: configuration(name: "a"))
        let second = FakeRemoteSession(configuration: configuration(name: "b"))
        _ = try await manager.add(first)
        _ = try await manager.add(second)

        let change = await manager.remove(second.id)
        XCTAssertEqual(change.focusedSessionID, first.id)
        await AsyncAssertEqual(await manager.count, 1)
    }

    func testRemovingLastSessionClearsFocus() async throws {
        let manager = SessionManager()
        let only = FakeRemoteSession(configuration: configuration(name: "a"))
        _ = try await manager.add(only)

        _ = await manager.remove(only.id)
        let focused = await manager.focusedSessionID
        XCTAssertNil(focused)
    }

    func testRemovingASlotFreesTheBudget() async throws {
        let manager = SessionManager(sessionLimit: 1)
        let first = FakeRemoteSession(configuration: configuration(name: "a"))
        _ = try await manager.add(first)
        _ = await manager.remove(first.id)
        _ = try await manager.add(FakeRemoteSession(configuration: configuration(name: "b")))
        await AsyncAssertEqual(await manager.count, 1)
    }

    func testDuplicateSessionIsRefused() async throws {
        let manager = SessionManager()
        let session = FakeRemoteSession(configuration: configuration(name: "a"))
        _ = try await manager.add(session)
        do {
            _ = try await manager.add(session)
            XCTFail("expected a duplicate session to be refused")
        } catch let error as DuplicateSessionError {
            XCTAssertEqual(error.sessionID, session.id)
        }
    }

    func testSessionsForProfileKeepStartOrder() async throws {
        let profileID = ProfileID()
        let profile = ConnectionProfile(
            id: profileID,
            displayName: "shared",
            endpoint: RemoteEndpoint(host: "shared.example", port: 3389)
        )
        let resolved = EffectiveProfileResolver().resolve(
            profile: profile,
            globalSettings: .default
        )
        let manager = SessionManager()
        let first = FakeRemoteSession(configuration: resolved)
        let second = FakeRemoteSession(configuration: resolved)
        _ = try await manager.add(first)
        _ = try await manager.add(second)

        let ids = await manager.sessions(for: profileID)
        XCTAssertEqual(ids, [first.id, second.id])
    }

    func testVisibilityPolicyBackgroundsUnfocusedSessions() async throws {
        let manager = SessionManager()
        let first = FakeRemoteSession(configuration: configuration(name: "a"))
        let second = FakeRemoteSession(configuration: configuration(name: "b"))
        _ = try await manager.add(first)
        _ = try await manager.add(second)

        await manager.applyVisibilityPolicy()
        await AsyncAssertEqual(await first.currentVisibility, .background)
        await AsyncAssertEqual(await second.currentVisibility, .focused)
    }

    func testDisconnectAllStopsEverySession() async throws {
        let manager = SessionManager()
        let first = FakeRemoteSession(configuration: configuration(name: "a"))
        let second = FakeRemoteSession(configuration: configuration(name: "b"))
        _ = try await manager.add(first)
        _ = try await manager.add(second)
        try await first.connect()
        try await second.connect()

        await manager.disconnectAll(reason: .sceneTerminating)
        await AsyncAssertEqual(await first.state, .disconnected)
        await AsyncAssertEqual(await second.state, .disconnected)
    }
}

func AsyncAssertEqual<T: Equatable>(
    _ value: @autoclosure () async -> T,
    _ expected: T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let actual = await value()
    XCTAssertEqual(actual, expected, file: file, line: line)
}
