import XCTest
import AppleAdapters
import Persistence
import SessionCore
@testable import mRemote

@MainActor
final class AppEnvironmentTests: XCTestCase {
    private func makeEnvironment(
        script: FakeRemoteSession.Script = .succeeds
    ) -> (AppEnvironment, InMemoryCredentialRepository) {
        let credentials = InMemoryCredentialRepository()
        let environment = AppEnvironment(
            store: InMemoryProfileStore(),
            credentials: credentials,
            trust: InMemoryTrustRepository(),
            factories: SessionFactoryRegistry(factories: [FakeSessionFactory(script: script)])
        )
        return (environment, credentials)
    }

    private func profile(_ name: String = "desk") -> ConnectionProfile {
        ConnectionProfile(
            displayName: name,
            endpoint: RemoteEndpoint(host: "\(name).example", port: 3389)
        )
    }

    func testSavingAProfileStoresThePasswordOutsideTheDocument() async throws {
        let (environment, credentials) = makeEnvironment()
        await environment.start()

        await environment.save(profile(), password: "secret")
        let saved = try XCTUnwrap(environment.profiles.first)
        let reference = try XCTUnwrap(saved.account.credentialReference)
        XCTAssertEqual(try credentials.password(for: reference), "secret")

        // The password must not be reachable from the persisted model itself.
        let encoded = try ProfileDocumentCodec().encode(
            ProfileDocument(profiles: environment.profiles)
        )
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("secret"))
    }

    func testRotatingAPasswordKeepsTheSameReference() async throws {
        let (environment, credentials) = makeEnvironment()
        await environment.start()
        await environment.save(profile(), password: "first")
        let reference = try XCTUnwrap(environment.profiles.first?.account.credentialReference)

        var updated = try XCTUnwrap(environment.profiles.first)
        updated.displayName = "renamed"
        await environment.save(updated, password: "second")

        XCTAssertEqual(environment.profiles.first?.account.credentialReference, reference)
        XCTAssertEqual(try credentials.password(for: reference), "second")
    }

    func testDeletingAProfileRemovesItsOrphanedCredential() async throws {
        let (environment, credentials) = makeEnvironment()
        await environment.start()
        await environment.save(profile(), password: "secret")
        let saved = try XCTUnwrap(environment.profiles.first)
        let reference = try XCTUnwrap(saved.account.credentialReference)

        await environment.delete(saved)
        XCTAssertTrue(environment.profiles.isEmpty)
        XCTAssertNil(try credentials.password(for: reference))
    }

    func testDuplicateDoesNotShareTheStoredPassword() async throws {
        let (environment, _) = makeEnvironment()
        await environment.start()
        await environment.save(profile(), password: "secret")
        let original = try XCTUnwrap(environment.profiles.first)

        await environment.duplicate(original)
        XCTAssertEqual(environment.profiles.count, 2)
        let copy = try XCTUnwrap(environment.profiles.first { $0.id != original.id })
        XCTAssertNil(copy.account.credentialReference)
    }

    func testConnectPresentsAWorkspaceAndRecordsTheConnection() async throws {
        let (environment, _) = makeEnvironment()
        await environment.start()
        await environment.save(profile(), password: nil)
        let saved = try XCTUnwrap(environment.profiles.first)

        await environment.connect(to: saved)
        let presented = try XCTUnwrap(environment.presentedSession)
        XCTAssertEqual(presented.displayName, saved.displayName)
        XCTAssertEqual(environment.runningSessions.count, 1)
        XCTAssertNotNil(environment.profiles.first?.lastConnectedAt)
    }

    func testReturningToTheListKeepsTheSessionRunning() async throws {
        let (environment, _) = makeEnvironment()
        await environment.start()
        await environment.save(profile(), password: nil)
        await environment.connect(to: try XCTUnwrap(environment.profiles.first))

        let presented = try XCTUnwrap(environment.presentedSession)
        presented.returnToList()

        XCTAssertNil(environment.presentedSession)
        XCTAssertEqual(environment.runningSessions.count, 1, "SES-02 keeps the connection alive")
    }

    func testDisconnectRemovesTheSessionAndFreesItsSlot() async throws {
        let (environment, _) = makeEnvironment()
        await environment.start()
        await environment.save(profile(), password: nil)
        await environment.connect(to: try XCTUnwrap(environment.profiles.first))

        let presented = try XCTUnwrap(environment.presentedSession)
        await presented.disconnect()

        XCTAssertNil(environment.presentedSession)
        XCTAssertTrue(environment.runningSessions.isEmpty)
        let remaining = await environment.sessions.count
        XCTAssertEqual(remaining, 0)
    }

    func testCertificateChallengeIsSurfacedRatherThanAutoAccepted() async throws {
        let (environment, _) = makeEnvironment(
            script: .requiresCertificateReview(.untrustedRoot)
        )
        await environment.start()
        await environment.save(profile(), password: nil)
        await environment.connect(to: try XCTUnwrap(environment.profiles.first))

        let presented = try XCTUnwrap(environment.presentedSession)
        XCTAssertNotNil(presented.pendingChallenge)
        XCTAssertEqual(presented.state, .awaitingUser)
    }

    func testAReviewThatTimesOutTakesItsSheetDown() async throws {
        let (environment, _) = makeEnvironment(
            script: .requiresCertificateReview(.untrustedRoot)
        )
        await environment.start()
        await environment.save(profile(), password: nil)
        await environment.connect(to: try XCTUnwrap(environment.profiles.first))
        let presented = try XCTUnwrap(environment.presentedSession)
        XCTAssertNotNil(presented.pendingChallenge)

        let found = await environment.sessions.session(for: presented.id)
        let fake = try XCTUnwrap(found as? FakeRemoteSession)
        await fake.simulateConnectionLoss(.connectionTimedOut)
        let deadline = Date().addingTimeInterval(5)
        while presented.state != .failed, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(presented.state, .failed)
        XCTAssertNil(presented.pendingChallenge, "nothing is left to answer")
    }
}
