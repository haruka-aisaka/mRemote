import XCTest
@testable import SessionCore

final class RDPFileTests: XCTestCase {
    private let sample = """
    screen mode id:i:2
    use multimon:i:0
    desktopwidth:i:1920
    desktopheight:i:1080
    full address:s:pc.example.lan:3390
    audiomode:i:2
    redirectclipboard:i:0
    username:s:CORP\\taro
    authentication level:i:0
    enablecredsspsupport:i:0
    """

    func testAFileGivesAProfile() throws {
        let file = RDPFile(text: sample)
        let profile = try XCTUnwrap(file.profile(named: "会社の PC"))
        XCTAssertEqual(profile.displayName, "会社の PC")
        XCTAssertEqual(profile.endpoint, RemoteEndpoint(host: "pc.example.lan", port: 3390))
        XCTAssertEqual(profile.account.username, "taro")
        XCTAssertEqual(profile.account.domain, "CORP")
        let rdp = try XCTUnwrap(profile.configuration.rdp)
        XCTAssertEqual(rdp.audioPlayback, .explicit(false))
        XCTAssertEqual(rdp.clipboardPolicy, .explicit(.disabled))
        // The size is the sender's screen unless the file turns dynamic
        // resolution off; the security settings are never taken.
        XCTAssertEqual(rdp.resolutionPolicy, .inherit)
        XCTAssertEqual(rdp.securityPolicy, .secureAutomatic)
        XCTAssertTrue(file.unsupportedSettings.isEmpty)
    }

    func testWindowsSavesUTF16WithAMark() throws {
        var data = Data([0xFF, 0xFE])
        data.append(sample.data(using: .utf16LittleEndian)!)
        let file = try XCTUnwrap(RDPFile(data: data))
        XCTAssertEqual(file.endpoint?.host, "pc.example.lan")
        XCTAssertNil(RDPFile(data: Data("hello".utf8)), "a file without an address is not one")
    }

    func testAddressesWithPortsAndIPv6() {
        XCTAssertEqual(RDPFile(text: "full address:s:10.0.0.5").endpoint, RemoteEndpoint(host: "10.0.0.5", port: 3389))
        XCTAssertEqual(
            RDPFile(text: "full address:s:host\nserver port:i:4000").endpoint?.port,
            4000
        )
        XCTAssertEqual(RDPFile(text: "full address:s:[fe80::1]:3391").endpoint, RemoteEndpoint(host: "fe80::1", port: 3391))
        XCTAssertEqual(RDPFile(text: "full address:s:fe80::1").endpoint, RemoteEndpoint(host: "fe80::1", port: 3389))
    }

    func testMicrosoftStyleLinks() throws {
        let url = try XCTUnwrap(URL(string: "rdp://full%20address=s:desk.example:3389&username=s:me@example.com&audiomode=i:0"))
        let file = try XCTUnwrap(RDPFile(url: url))
        XCTAssertEqual(file.endpoint, RemoteEndpoint(host: "desk.example", port: 3389))
        XCTAssertEqual(file.account.username, "me@example.com")
        XCTAssertEqual(file.configuration().audioPlayback, .explicit(true))
    }

    /// As iOS hands them over: CFURL accepts the bare colons that
    /// `URL(string:)` refuses.
    func testLinksWithBareColons() throws {
        let raw = "rdp://full%20address=s:192.168.0.10:3390&username=s:taro"
        let url = try XCTUnwrap(CFURLCreateWithString(nil, raw as CFString, nil) as URL?)
        let file = try XCTUnwrap(RDPFile(url: url))
        XCTAssertEqual(file.endpoint, RemoteEndpoint(host: "192.168.0.10", port: 3390))
        XCTAssertEqual(file.account.username, "taro")
    }

    func testPlainLinks() throws {
        let file = try XCTUnwrap(RDPFile(url: URL(string: "rdp://taro@192.168.0.10:3390")!))
        XCTAssertEqual(file.endpoint, RemoteEndpoint(host: "192.168.0.10", port: 3390))
        XCTAssertEqual(file.account.username, "taro")
        XCTAssertNil(RDPFile(url: URL(string: "rdp://")!))
        XCTAssertNil(RDPFile(url: URL(string: "https://example.com")!))
    }

    func testUnsupportedSettingsAreNamed() {
        let file = RDPFile(text: """
        full address:s:app.example
        remoteapplicationmode:i:1
        remoteapplicationprogram:s:||excel
        gatewayhostname:s:gw.example
        gatewayusagemethod:i:1
        """)
        XCTAssertEqual(file.unsupportedSettings, [])
        XCTAssertEqual(file.configuration().remoteApp, RemoteAppConfiguration(program: "||excel"))
        let gateway = file.configuration().gateway
        XCTAssertEqual(gateway?.host, "gw.example")
        XCTAssertEqual(gateway?.port, 443)
        XCTAssertEqual(gateway?.usesComputerCredentials, true)
    }

    func testAGatewayWithAPortAndItsOwnSignIn() {
        let file = RDPFile(text: """
        full address:s:pc.internal
        gatewayhostname:s:gw.example:8443
        gatewayusagemethod:i:2
        promptcredentialonce:i:0
        """)
        let gateway = file.configuration().gateway
        XCTAssertEqual(gateway?.host, "gw.example")
        XCTAssertEqual(gateway?.port, 8443)
        XCTAssertEqual(gateway?.usesComputerCredentials, false)
        XCTAssertEqual(gateway?.bypassesLocalAddresses, true)
        XCTAssertNil(RDPFile(text: "full address:s:pc\ngatewayhostname:s:gw\ngatewayusagemethod:i:0")
            .configuration().gateway, "a gateway the file says not to use is not used")
    }
}
