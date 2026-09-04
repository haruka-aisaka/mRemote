import XCTest
@testable import SessionCore

final class SessionFactoryRegistryTests: XCTestCase {
    private let configuration = EffectiveProfileResolver().resolve(
        profile: ConnectionProfile(
            displayName: "desk",
            endpoint: RemoteEndpoint(host: "desk.example", port: 3389)
        ),
        globalSettings: .default
    )

    func testRegisteredKindProducesASession() async throws {
        let registry = SessionFactoryRegistry(factories: [FakeSessionFactory()])
        let session = try await registry.makeSession(kind: .rdp, configuration: configuration)
        await AsyncAssertEqual(await session.state, .idle)
    }

    func testUnregisteredKindIsRefused() async {
        let registry = SessionFactoryRegistry()
        do {
            _ = try await registry.makeSession(kind: .rdp, configuration: configuration)
            XCTFail("expected an unsupported protocol error")
        } catch let error as UnsupportedProtocolError {
            XCTAssertEqual(error.protocolKind, .rdp)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRegisteringReplacesTheFactoryForItsKind() async throws {
        let registry = SessionFactoryRegistry(factories: [FakeSessionFactory()])
        await registry.register(FakeSessionFactory(script: .requiresCredential))

        let session = try await registry.makeSession(kind: .rdp, configuration: configuration)
        try await session.connect()
        await AsyncAssertEqual(await session.state, .awaitingUser)
        await AsyncAssertEqual(await registry.registeredKinds, Set([ProtocolKind.rdp]))
    }
}
