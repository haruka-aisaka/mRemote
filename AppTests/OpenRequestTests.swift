import XCTest
import AppleAdapters
import Persistence
import SessionCore
@testable import mRemote

@MainActor
final class OpenRequestTests: XCTestCase {
    private func makeEnvironment() async -> AppEnvironment {
        let saved = ConnectionProfile(
            displayName: "desk",
            endpoint: RemoteEndpoint(host: "desk.example", port: 3389),
            account: RemoteAccount(username: "tester")
        )
        let environment = AppEnvironment(
            store: InMemoryProfileStore(document: ProfileDocument(profiles: [saved])),
            credentials: InMemoryCredentialRepository(),
            trust: InMemoryTrustRepository(),
            factories: SessionFactoryRegistry(factories: [FakeSessionFactory()])
        )
        await environment.start()
        return environment
    }

    func testALinkToASavedComputerConnects() async throws {
        let environment = await makeEnvironment()
        await environment.open(URL(string: "rdp://tester@DESK.example")!)
        XCTAssertNil(environment.pendingImport)
        XCTAssertEqual(environment.presentedSession?.displayName, "desk")
    }

    func testALinkToANewComputerWaitsForTheUser() async throws {
        let environment = await makeEnvironment()
        await environment.open(URL(string: "rdp://desk.example:3390")!)
        XCTAssertNil(environment.presentedSession, "a new host is never connected to from a link")
        XCTAssertEqual(environment.pendingImport?.portText, "3390")
    }

    func testTheShortcutsLinkOpensByNameOrIdentifier() async throws {
        let environment = await makeEnvironment()
        await environment.open(URL(string: "mremote://connect?profile=desk")!)
        XCTAssertEqual(environment.presentedSession?.displayName, "desk")
    }
}
