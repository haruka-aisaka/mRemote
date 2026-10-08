import Darwin
import Foundation
import Network
import SessionCore

/// Sends the magic packet and waits for the computer to answer.
///
/// A broadcast from an iPhone or iPad needs Apple's multicast networking
/// entitlement on a device; without it the send fails and the packet can
/// still go to a router or relay that forwards it, by unicast.
enum WakeOnLANSender {
    enum Failure: Error {
        case invalidAddress
        case sendFailed(Int32)
    }

    /// Three copies a short moment apart: a single UDP datagram is easily
    /// lost on Wi-Fi.
    static func send(_ configuration: WakeOnLANConfiguration) async throws {
        guard let mac = configuration.macBytes, let packet = MagicPacket.packet(for: mac) else {
            throw Failure.invalidAddress
        }
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(200)) }
            try sendOnce(packet, to: configuration.targetAddress, port: configuration.port)
        }
    }

    private static func sendOnce(_ packet: Data, to host: String, port: UInt16) throws {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw Failure.sendFailed(errno) }
        defer { close(descriptor) }
        var enable: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &enable, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { throw Failure.invalidAddress }
        let sent = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else { throw Failure.sendFailed(errno) }
    }

    /// True once something accepts a TCP connection on the port, polling
    /// until the deadline: a woken PC takes a while to bring RDP up.
    static func waitUntilReachable(host: String, port: UInt16, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return false }
            if await probe(host: host, port: port) { return true }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }

    private static func probe(host: String, port: UInt16) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        return await withCheckedContinuation { continuation in
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: true) }
                    connection.cancel()
                case .failed, .waiting:
                    if once.claim() { continuation.resume(returning: false) }
                    connection.cancel()
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if once.claim() { continuation.resume(returning: false) }
                connection.cancel()
            }
        }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
