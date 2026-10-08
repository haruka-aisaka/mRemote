import Foundation

/// The settings of a Microsoft `.rdp` file, or of an `rdp://` link that
/// carries the same `name:type:value` settings.
///
/// Only what a profile can hold is taken over. Nothing in a file can weaken
/// the transport: `authentication level` and `enablecredsspsupport` are
/// read past, because a file is something anyone can send.
public struct RDPFile: Hashable, Sendable {
    /// Lower-cased names to their values, the type letter dropped.
    public private(set) var settings: [String: String]

    public init(settings: [String: String]) {
        self.settings = Dictionary(settings.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
    }

    /// The text of a file: one `name:type:value` per line.
    public init(text: String) {
        var settings: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let setting = Self.setting(String(line)) else { continue }
            settings[setting.name] = setting.value
        }
        self.settings = settings
    }

    /// A file as saved by Windows (UTF-16 with a byte order mark) or by
    /// anything else (UTF-8).
    public init?(data: Data) {
        let text: String?
        if data.starts(with: [0xFF, 0xFE]) {
            text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if data.starts(with: [0xFE, 0xFF]) {
            text = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            text = String(data: data.dropFirst(3), encoding: .utf8)
        } else if data.count >= 2, data[data.startIndex + 1] == 0, data[data.startIndex] != 0 {
            // UTF-16LE without a mark: ASCII with every other byte zero.
            text = String(data: data, encoding: .utf16LittleEndian)
        } else {
            text = String(data: data, encoding: .utf8)
        }
        guard let text else { return nil }
        self.init(text: text)
        guard fullAddress != nil else { return nil }
    }

    /// `rdp://full%20address=s:host:3389&username=s:me`, as Microsoft's
    /// clients take it, or the plain `rdp://[user@]host[:port]`.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == "rdp" else { return nil }
        let raw = url.absoluteString.dropFirst("rdp:".count).drop { $0 == "/" }
        guard !raw.isEmpty else { return nil }
        if raw.contains("=") {
            var settings: [String: String] = [:]
            for part in raw.split(separator: "&") {
                let pair = part.split(separator: "=", maxSplits: 1)
                guard pair.count == 2,
                      let name = String(pair[0]).removingPercentEncoding,
                      let rest = String(pair[1]).removingPercentEncoding,
                      let setting = Self.setting("\(name):\(rest)") else { continue }
                settings[setting.name] = setting.value
            }
            self.settings = settings
        } else {
            guard let decoded = String(raw).removingPercentEncoding else { return nil }
            let trimmed = decoded.hasSuffix("/") ? String(decoded.dropLast()) : decoded
            var settings: [String: String] = [:]
            if let at = trimmed.lastIndex(of: "@") {
                settings["username"] = String(trimmed[..<at])
                settings["full address"] = String(trimmed[trimmed.index(after: at)...])
            } else {
                settings["full address"] = trimmed
            }
            self.settings = settings
        }
        guard fullAddress != nil else { return nil }
    }

    private static func setting(_ line: String) -> (name: String, value: String)? {
        let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, ["s", "i", "b"].contains(parts[1].lowercased()) else { return nil }
        let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return nil }
        return (name, String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func string(_ name: String) -> String? {
        guard let value = settings[name], !value.isEmpty else { return nil }
        return value
    }

    public func integer(_ name: String) -> Int? {
        string(name).flatMap { Int($0) }
    }

    /// `full address`, falling back to the older `alternate full address`.
    public var fullAddress: String? {
        string("full address") ?? string("alternate full address")
    }

    /// The host and port, from `full address` and `server port`.
    public var endpoint: RemoteEndpoint? {
        guard let address = fullAddress else { return nil }
        var host = address
        var port = integer("server port").flatMap(UInt16.init(exactly:)) ?? 3389
        if address.hasPrefix("["), let close = address.firstIndex(of: "]") {
            // [IPv6]:port
            host = String(address[address.index(after: address.startIndex)..<close])
            let rest = address[address.index(after: close)...]
            if rest.hasPrefix(":"), let value = UInt16(rest.dropFirst()) { port = value }
        } else if address.filter({ $0 == ":" }).count == 1, let colon = address.lastIndex(of: ":") {
            host = String(address[..<colon])
            if let value = UInt16(address[address.index(after: colon)...]) { port = value }
        }
        host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return nil }
        return RemoteEndpoint(host: host, port: port)
    }

    /// `DOMAIN\user` is split; `user@domain` is a user name as it stands.
    public var account: RemoteAccount {
        var username = string("username")
        var domain = string("domain")
        if let name = username, let slash = name.firstIndex(of: "\\") {
            domain = domain ?? String(name[..<slash])
            username = String(name[name.index(after: slash)...])
        }
        return RemoteAccount(username: username, domain: domain)
    }

    public var gatewayHost: String? {
        // 0 is "do not use", 4 "detect": a host left behind with either is
        // not one the file asks for.
        guard let usage = integer("gatewayusagemethod"), usage == 1 || usage == 2 else { return nil }
        return string("gatewayhostname")
    }

    /// What a profile can take from the file; the rest stays inherited.
    public func configuration(base: RDPConfiguration = RDPConfiguration()) -> RDPConfiguration {
        var configuration = base
        if let mode = integer("audiomode") {
            // 0 plays here; 1 leaves it on the remote and 2 plays nowhere.
            configuration.audioPlayback = .explicit(mode == 0)
        }
        if let clipboard = integer("redirectclipboard") {
            configuration.clipboardPolicy = .explicit(clipboard == 0 ? .disabled : .bidirectional)
        }
        if integer("dynamic resolution") == 0,
           let width = integer("desktopwidth"), let height = integer("desktopheight"),
           width > 0, height > 0 {
            configuration.resolutionPolicy = .explicit(.fixed(width: width, height: height))
        }
        return configuration
    }

    /// A new profile, named after the file or the host.
    public func profile(named name: String? = nil) -> ConnectionProfile? {
        guard let endpoint else { return nil }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ConnectionProfile(
            displayName: trimmed.flatMap { $0.isEmpty ? nil : $0 } ?? endpoint.host,
            endpoint: endpoint,
            account: account,
            configuration: .rdp(configuration())
        )
    }

    /// Settings in the file this app does not carry out, named for the user.
    public var unsupportedSettings: [String] {
        var names: [String] = []
        if string("remoteapplicationprogram") != nil, integer("remoteapplicationmode") == 1 {
            names.append("RemoteApp")
        }
        if gatewayHost != nil {
            names.append("RD Gateway")
        }
        if integer("use multimon") == 1 {
            names.append("use multimon")
        }
        return names
    }
}
