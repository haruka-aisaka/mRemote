import Foundation

public enum ResolutionPolicy: Hashable, Sendable, Codable {
    /// Follow the viewport, requesting a remote resize when the server
    /// negotiated the display channel.
    case adaptive
    case fixed(width: Int, height: Int)
}

public enum InitialScale: String, Hashable, Sendable, Codable, CaseIterable {
    case fit
    case oneToOne
}

public enum DisplayQuality: Hashable, Sendable, Codable {
    case automatic
    case explicit(colorDepth: Int)
}

public enum KeyboardLayoutPreference: String, Hashable, Sendable, Codable, CaseIterable {
    /// The only configuration in which Eisu/Kana to Muhenkan/Henkan is
    /// promised. The connection form says so where the other options are
    /// selected.
    case japanese
    case us
    case automatic
}

public enum ClipboardPolicy: String, Hashable, Sendable, Codable, CaseIterable {
    case disabled
    /// Permission to transfer in both directions on an explicit user action.
    /// It does not mean the pasteboard is monitored.
    case bidirectional
    case sendOnly
    case receiveOnly

    public var allowsSend: Bool { self == .bidirectional || self == .sendOnly }
    public var allowsReceive: Bool { self == .bidirectional || self == .receiveOnly }
}

public enum ScrollDirection: String, Hashable, Sendable, Codable, CaseIterable {
    case normal
    case reversed
}

public enum ReconnectPolicy: String, Hashable, Sendable, Codable, CaseIterable {
    case disabled
    case automatic
}

/// How much transport security may be negotiated down. There is no inherit
/// case: a global default that silently weakens every connection is exactly
/// what this setting exists to prevent.
public enum SecurityPolicy: String, Hashable, Sendable, Codable, CaseIterable {
    case secureAutomatic
    case nlaRequired
    case tlsRequired
    /// Legacy RDP security, only ever by explicit per-profile choice, and
    /// surfaced in the UI as a warning.
    case legacyExplicit
}

/// Version 1 of the RDP-specific profile payload.
public struct RDPConfiguration: Hashable, Sendable, Codable {
    public var resolutionPolicy: Inheritable<ResolutionPolicy>
    public var initialScale: Inheritable<InitialScale>
    public var displayQuality: Inheritable<DisplayQuality>
    public var keyboardLayout: Inheritable<KeyboardLayoutPreference>
    public var audioPlayback: Inheritable<Bool>
    public var clipboardPolicy: Inheritable<ClipboardPolicy>
    public var scrollDirection: Inheritable<ScrollDirection>
    public var reconnectPolicy: Inheritable<ReconnectPolicy>
    public var securityPolicy: SecurityPolicy

    public init(
        resolutionPolicy: Inheritable<ResolutionPolicy> = .inherit,
        initialScale: Inheritable<InitialScale> = .inherit,
        displayQuality: Inheritable<DisplayQuality> = .inherit,
        keyboardLayout: Inheritable<KeyboardLayoutPreference> = .inherit,
        audioPlayback: Inheritable<Bool> = .inherit,
        clipboardPolicy: Inheritable<ClipboardPolicy> = .inherit,
        scrollDirection: Inheritable<ScrollDirection> = .inherit,
        reconnectPolicy: Inheritable<ReconnectPolicy> = .inherit,
        securityPolicy: SecurityPolicy = .secureAutomatic
    ) {
        self.resolutionPolicy = resolutionPolicy
        self.initialScale = initialScale
        self.displayQuality = displayQuality
        self.keyboardLayout = keyboardLayout
        self.audioPlayback = audioPlayback
        self.clipboardPolicy = clipboardPolicy
        self.scrollDirection = scrollDirection
        self.reconnectPolicy = reconnectPolicy
        self.securityPolicy = securityPolicy
    }
}
