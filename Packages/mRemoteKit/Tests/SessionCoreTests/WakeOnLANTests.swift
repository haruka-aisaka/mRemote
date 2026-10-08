import XCTest
@testable import SessionCore

final class WakeOnLANTests: XCTestCase {
    func testAddressesInTheUsualSpellings() {
        let expected: [UInt8] = [0xAA, 0xBB, 0xCC, 0x01, 0x02, 0x03]
        XCTAssertEqual(MagicPacket.macBytes("AA:BB:CC:01:02:03"), expected)
        XCTAssertEqual(MagicPacket.macBytes("aa-bb-cc-01-02-03"), expected)
        XCTAssertEqual(MagicPacket.macBytes("aabbcc010203"), expected)
        XCTAssertNil(MagicPacket.macBytes("aa:bb:cc:01:02"))
        XCTAssertNil(MagicPacket.macBytes("zz:bb:cc:01:02:03"))
    }

    func testThePacketIsSyncThenSixteenCopies() throws {
        let mac: [UInt8] = [1, 2, 3, 4, 5, 6]
        let packet = try XCTUnwrap(MagicPacket.packet(for: mac))
        XCTAssertEqual(packet.count, 102)
        XCTAssertEqual(Array(packet.prefix(6)), [UInt8](repeating: 0xFF, count: 6))
        XCTAssertEqual(Array(packet.suffix(6)), mac)
    }

    func testOlderProfilesDecodeWithoutGroupsOrWake() throws {
        let profile = ConnectionProfile(displayName: "a", endpoint: RemoteEndpoint(host: "h", port: 3389))
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: data)
        XCTAssertFalse(decoded.isFavorite)
        XCTAssertNil(decoded.groupName)
        XCTAssertNil(decoded.wakeOnLAN)
        var favourite = profile
        favourite.isFavorite = true
        favourite.group = "  自宅 "
        XCTAssertEqual(favourite.groupName, "自宅")
        XCTAssertTrue(try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(favourite)).isFavorite)
    }
}
