import XCTest
@testable import SessionCore

final class EffectiveProfileResolverTests: XCTestCase {
    private func profile(_ rdp: RDPConfiguration) -> ConnectionProfile {
        ConnectionProfile(
            displayName: "desk",
            endpoint: RemoteEndpoint(host: "desk.example", port: 3389),
            configuration: .rdp(rdp)
        )
    }

    func testInheritTakesTheGlobalValue() {
        let settings = GlobalSettings(keyboardLayout: .us, scrollDirection: .reversed)
        let resolved = EffectiveProfileResolver().resolve(
            profile: profile(RDPConfiguration()),
            globalSettings: settings
        )
        XCTAssertEqual(resolved.keyboardLayout, .us)
        XCTAssertEqual(resolved.scrollDirection, .reversed)
    }

    func testExplicitOverridesTheGlobalValue() {
        let settings = GlobalSettings(scrollDirection: .reversed)
        let resolved = EffectiveProfileResolver().resolve(
            profile: profile(RDPConfiguration(scrollDirection: .explicit(.normal))),
            globalSettings: settings
        )
        XCTAssertEqual(resolved.scrollDirection, .normal)
    }

    func testSecurityPolicyHasNoGlobalOverride() {
        let resolved = EffectiveProfileResolver().resolve(
            profile: profile(RDPConfiguration(securityPolicy: .nlaRequired)),
            globalSettings: .default
        )
        XCTAssertEqual(resolved.securityPolicy, .nlaRequired)
    }

    func testJapaneseKeyGuaranteeFollowsLayout() {
        let japanese = EffectiveProfileResolver().resolve(
            profile: profile(RDPConfiguration(keyboardLayout: .explicit(.japanese))),
            globalSettings: .default
        )
        let us = EffectiveProfileResolver().resolve(
            profile: profile(RDPConfiguration(keyboardLayout: .explicit(.us))),
            globalSettings: .default
        )
        XCTAssertTrue(japanese.guaranteesJapaneseImeKeys)
        XCTAssertFalse(us.guaranteesJapaneseImeKeys)
    }

    func testRuntimeStateStartsFromResolvedConfiguration() {
        let resolved = EffectiveProfileResolver().resolve(
            profile: profile(RDPConfiguration(
                initialScale: .explicit(.oneToOne),
                scrollDirection: .explicit(.reversed)
            )),
            globalSettings: .default
        )
        let runtime = SessionRuntimeState(from: resolved)
        XCTAssertEqual(runtime.scale, .oneToOne)
        XCTAssertEqual(runtime.scrollDirection, .reversed)
        XCTAssertEqual(runtime.zoom, 1.0)
    }

    func testDuplicateDropsCredentialAndConnectionHistory() {
        var original = profile(RDPConfiguration())
        original.account.credentialReference = CredentialReference()
        original.lastConnectedAt = Date()

        let copy = original.duplicated(displayName: "desk copy")
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertNil(copy.account.credentialReference)
        XCTAssertNil(copy.lastConnectedAt)
        XCTAssertEqual(copy.configuration, original.configuration)
    }

    func testIPLiteralDetection() {
        XCTAssertTrue(RemoteEndpoint(host: "192.168.1.10", port: 3389).isIPLiteral)
        XCTAssertTrue(RemoteEndpoint(host: "fe80::1", port: 3389).isIPLiteral)
        XCTAssertTrue(RemoteEndpoint(host: "[fe80::1]", port: 3389).isIPLiteral)
        XCTAssertFalse(RemoteEndpoint(host: "desk.example", port: 3389).isIPLiteral)
        XCTAssertFalse(RemoteEndpoint(host: "192.168.1", port: 3389).isIPLiteral)
    }
}
