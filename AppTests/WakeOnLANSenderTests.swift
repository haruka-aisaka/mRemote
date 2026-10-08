import Darwin
import XCTest
import SessionCore
@testable import mRemote

final class WakeOnLANSenderTests: XCTestCase {
    /// The packet reaches a listener, three times, as 102 bytes of sync and
    /// address.
    func testTheMagicPacketIsSent() async throws {
        let receiver = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        XCTAssertGreaterThanOrEqual(receiver, 0)
        defer { close(receiver) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(receiver, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(receiver, $0, &length) }
        }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(receiver, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        try await WakeOnLANSender.send(WakeOnLANConfiguration(
            macAddress: "01:23:45:67:89:ab",
            targetAddress: "127.0.0.1",
            port: UInt16(bigEndian: address.sin_port)
        ))
        var buffer = [UInt8](repeating: 0, count: 256)
        var packets = 0
        while true {
            let count = recv(receiver, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            XCTAssertEqual(count, 102)
            XCTAssertEqual(Array(buffer[0..<6]), [UInt8](repeating: 0xFF, count: 6))
            XCTAssertEqual(Array(buffer[96..<102]), [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB])
            packets += 1
            if packets == 3 { break }
        }
        XCTAssertEqual(packets, 3)
    }

    func testABadAddressIsRefused() async {
        do {
            try await WakeOnLANSender.send(WakeOnLANConfiguration(macAddress: "nope"))
            XCTFail("sent a packet for no address")
        } catch {}
    }
}
