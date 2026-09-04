import XCTest
@testable import SessionCore

final class FakeRemoteSessionTests: XCTestCase {
    private let configuration = EffectiveProfileResolver().resolve(
        profile: ConnectionProfile(
            displayName: "desk",
            endpoint: RemoteEndpoint(host: "desk.example", port: 3389)
        ),
        globalSettings: .default
    )

    func testSuccessfulConnectEmitsOrderedStates() async throws {
        let session = FakeRemoteSession(configuration: configuration)
        let events = await session.controlEvents()
        try await session.connect()

        var states: [SessionState] = []
        for await event in events {
            if case .stateChanged(let state, _) = event { states.append(state) }
            if states.count == 2 { break }
        }
        XCTAssertEqual(states, [.connecting, .connected])
    }

    func testCredentialChallengeBlocksUntilAnswered() async throws {
        let session = FakeRemoteSession(configuration: configuration, script: .requiresCredential)
        try await session.connect()

        let state = await session.state
        XCTAssertEqual(state, .awaitingUser)
        guard let challenge = await session.pendingChallenge else {
            return XCTFail("expected a pending challenge")
        }

        try await session.respond(
            to: challenge.id,
            with: .credential(username: "user", domain: nil, password: "secret", save: false)
        )
        await AsyncAssertEqual(await session.state, .connected)
        await AsyncAssertEqual(await session.generation, SessionGeneration(2))
    }

    func testAnsweringAChallengeTwiceIsRefused() async throws {
        let session = FakeRemoteSession(configuration: configuration, script: .requiresCredential)
        try await session.connect()
        guard let challenge = await session.pendingChallenge else {
            return XCTFail("expected a pending challenge")
        }
        try await session.respond(to: challenge.id, with: .trustOnce)

        do {
            try await session.respond(to: challenge.id, with: .trustOnce)
            XCTFail("expected the second answer to be refused")
        } catch let error as StaleChallengeError {
            XCTAssertEqual(error.challengeID, challenge.id)
        }
    }

    func testCancellingAChallengeDisconnects() async throws {
        let session = FakeRemoteSession(
            configuration: configuration,
            script: .requiresCertificateReview(.untrustedRoot)
        )
        try await session.connect()
        guard let challenge = await session.pendingChallenge else {
            return XCTFail("expected a pending challenge")
        }
        try await session.respond(to: challenge.id, with: .cancel)
        await AsyncAssertEqual(await session.state, .disconnected)
    }

    func testDisconnectIsIdempotent() async throws {
        let session = FakeRemoteSession(configuration: configuration)
        try await session.connect()
        await session.disconnect(reason: .userRequested)
        await session.disconnect(reason: .userRequested)
        await AsyncAssertEqual(await session.state, .disconnected)
    }

    func testFailingScriptReportsErrorAndFailedState() async throws {
        let session = FakeRemoteSession(
            configuration: configuration,
            script: .fails(.authenticationFailed)
        )
        let events = await session.controlEvents()
        try await session.connect()

        var seenError: RemoteSessionError?
        for await event in events {
            if case .error(let error) = event {
                seenError = error
                break
            }
        }
        XCTAssertEqual(seenError, .authenticationFailed)
        await AsyncAssertEqual(await session.state, .failed)
    }

    func testAuthenticationFailureIsNotAutoRetried() {
        XCTAssertFalse(RemoteSessionError.authenticationFailed.isRetriable)
        XCTAssertFalse(RemoteSessionError.accountRestricted.isRetriable)
        XCTAssertTrue(RemoteSessionError.connectionTimedOut.isRetriable)
    }

    func testOnlySoundCertificatesOfferApproval() {
        XCTAssertTrue(CertificateDisposition.untrustedRoot.allowsUserApproval)
        XCTAssertTrue(CertificateDisposition.hostnameUnverifiable.allowsUserApproval)
        XCTAssertFalse(CertificateDisposition.rejected(reason: "expired").allowsUserApproval)
        XCTAssertFalse(
            CertificateDisposition.fingerprintChanged(previousLeafSHA256: "aa").allowsUserApproval
        )
    }
}
