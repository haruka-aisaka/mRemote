import Foundation

/// How to wake a computer before connecting to it.
public struct WakeOnLANConfiguration: Hashable, Sendable, Codable {
    /// Six bytes, written with ':' or '-' between them, or none.
    public var macAddress: String
    /// Where the magic packet goes: the local broadcast address by default,
    /// or a router or relay that forwards it.
    public var targetAddress: String
    public var port: UInt16
    /// Sent on every connect, not only from the list's 起動 action.
    public var wakesBeforeConnecting: Bool

    public static let defaultTarget = "255.255.255.255"
    public static let defaultPort: UInt16 = 9

    public init(
        macAddress: String,
        targetAddress: String = WakeOnLANConfiguration.defaultTarget,
        port: UInt16 = WakeOnLANConfiguration.defaultPort,
        wakesBeforeConnecting: Bool = true
    ) {
        self.macAddress = macAddress
        self.targetAddress = targetAddress
        self.port = port
        self.wakesBeforeConnecting = wakesBeforeConnecting
    }

    /// Nil when the address is not six bytes.
    public var macBytes: [UInt8]? { MagicPacket.macBytes(macAddress) }
}

public enum MagicPacket {
    /// "AA:BB:CC:DD:EE:FF", "aa-bb-cc-dd-ee-ff" or "aabbccddeeff".
    public static func macBytes(_ text: String) -> [UInt8]? {
        let hex = text.filter { !":-. ".contains($0) }
        guard hex.count == 12 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// Six 0xFF bytes, then the address sixteen times: 102 bytes.
    public static func packet(for mac: [UInt8]) -> Data? {
        guard mac.count == 6 else { return nil }
        var data = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { data.append(contentsOf: mac) }
        return data
    }
}
