import XCTest
import SessionCore
@testable import mRemote

@MainActor
final class ProfileEditorModelTests: XCTestCase {
    func testHostAndPortAreRequired() {
        let model = ProfileEditorModel(mode: .create)
        XCTAssertFalse(model.isValid)

        model.host = "desk.example"
        XCTAssertTrue(model.isValid)

        model.portText = "0"
        XCTAssertFalse(model.isValid, "port 0 is not a usable port")

        model.portText = "70000"
        XCTAssertFalse(model.isValid, "a port above 65535 does not fit")

        model.portText = "3390"
        XCTAssertTrue(model.isValid)
    }

    func testDisplayNameFallsBackToTheHost() {
        let model = ProfileEditorModel(mode: .create)
        model.host = "  desk.example  "
        let profile = model.makeProfile()
        XCTAssertEqual(profile?.displayName, "desk.example")
        XCTAssertEqual(profile?.endpoint.host, "desk.example")
    }

    func testEditingKeepsTheIdentityAndCredentialReference() {
        let reference = CredentialReference()
        var existing = ConnectionProfile(
            displayName: "desk",
            endpoint: RemoteEndpoint(host: "desk.example", port: 3389),
            account: RemoteAccount(username: "user", credentialReference: reference)
        )
        existing.lastConnectedAt = Date(timeIntervalSince1970: 1)

        let model = ProfileEditorModel(mode: .edit(existing))
        model.displayName = "desk renamed"
        let updated = model.makeProfile()

        XCTAssertEqual(updated?.id, existing.id)
        XCTAssertEqual(updated?.displayName, "desk renamed")
        XCTAssertEqual(updated?.account.credentialReference, reference)
        XCTAssertEqual(updated?.lastConnectedAt, existing.lastConnectedAt)
    }

    func testEmptyUsernameBecomesNilRatherThanAnEmptyString() {
        let model = ProfileEditorModel(mode: .create)
        model.host = "desk.example"
        model.username = ""
        model.domain = ""
        let profile = model.makeProfile()
        XCTAssertNil(profile?.account.username)
        XCTAssertNil(profile?.account.domain)
    }

    func testJapaneseKeyWarningOnlyForNonJapaneseLayouts() {
        let model = ProfileEditorModel(mode: .create)
        XCTAssertFalse(model.showsJapaneseKeyWarning, "inherit must not warn on its own")

        model.keyboardLayout = .explicit(.japanese)
        XCTAssertFalse(model.showsJapaneseKeyWarning)

        model.keyboardLayout = .explicit(.us)
        XCTAssertTrue(model.showsJapaneseKeyWarning)
    }

    func testLegacySecurityIsFlagged() {
        let model = ProfileEditorModel(mode: .create)
        XCTAssertFalse(model.showsLegacySecurityWarning)
        model.securityPolicy = .legacyExplicit
        XCTAssertTrue(model.showsLegacySecurityWarning)
    }

    func testChoosingLegacySecurityAsksFirst() {
        let model = ProfileEditorModel(mode: .create)
        model.choose(.legacyExplicit)
        XCTAssertTrue(model.isConfirmingLegacySecurity)
        XCTAssertEqual(model.securityPolicy, .secureAutomatic, "nothing changes before consent")
        model.declineLegacySecurity()
        XCTAssertEqual(model.securityPolicy, .secureAutomatic)

        model.choose(.legacyExplicit)
        model.confirmLegacySecurity()
        XCTAssertEqual(model.securityPolicy, .legacyExplicit)
        XCTAssertFalse(model.isConfirmingLegacySecurity)

        model.choose(.nlaRequired)
        XCTAssertEqual(model.securityPolicy, .nlaRequired, "leaving legacy needs no consent")
        XCTAssertFalse(model.isConfirmingLegacySecurity)
    }

    func testConfigurationIsCarriedIntoTheProfile() {
        let model = ProfileEditorModel(mode: .create)
        model.host = "desk.example"
        model.clipboardPolicy = .explicit(.receiveOnly)
        model.scrollDirection = .explicit(.reversed)
        model.audioPlayback = .explicit(false)

        let rdp = model.makeProfile()?.configuration.rdp
        XCTAssertEqual(rdp?.clipboardPolicy, .explicit(.receiveOnly))
        XCTAssertEqual(rdp?.scrollDirection, .explicit(.reversed))
        XCTAssertEqual(rdp?.audioPlayback, .explicit(false))
    }
}
