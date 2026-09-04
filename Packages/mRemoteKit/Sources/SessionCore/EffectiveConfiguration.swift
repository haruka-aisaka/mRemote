import Foundation

/// What one connection attempt actually runs with, resolved once at connect
/// time and immutable thereafter. Changing a profile or a global default while
/// a session is live has no effect on it until the next connect, which is what
/// keeps the handshake parameters consistent with what the server was told.
public struct EffectiveConnectionConfiguration: Hashable, Sendable {
    public let profileID: ProfileID?
    public let displayName: String
    public let endpoint: RemoteEndpoint
    public let account: RemoteAccount
    public let resolutionPolicy: ResolutionPolicy
    public let initialScale: InitialScale
    public let displayQuality: DisplayQuality
    public let keyboardLayout: KeyboardLayoutPreference
    public let audioPlayback: Bool
    public let clipboardPolicy: ClipboardPolicy
    public let scrollDirection: ScrollDirection
    public let reconnectPolicy: ReconnectPolicy
    public let securityPolicy: SecurityPolicy

    /// Eisu/Kana to Muhenkan/Henkan is only promised for the Japanese layout,
    /// so the UI can warn where a profile has opted out of it.
    public var guaranteesJapaneseImeKeys: Bool { keyboardLayout == .japanese }
}

public struct EffectiveProfileResolver: Sendable {
    public init() {}

    public func resolve(
        profile: ConnectionProfile,
        globalSettings: GlobalSettings
    ) -> EffectiveConnectionConfiguration {
        guard let rdp = profile.configuration.rdp else {
            preconditionFailure("unhandled protocol configuration \(profile.configuration.kind)")
        }
        return EffectiveConnectionConfiguration(
            profileID: profile.id,
            displayName: profile.displayName,
            endpoint: profile.endpoint,
            account: profile.account,
            resolutionPolicy: rdp.resolutionPolicy.resolved(default: globalSettings.resolutionPolicy),
            initialScale: rdp.initialScale.resolved(default: globalSettings.initialScale),
            displayQuality: rdp.displayQuality.resolved(default: globalSettings.displayQuality),
            keyboardLayout: rdp.keyboardLayout.resolved(default: globalSettings.keyboardLayout),
            audioPlayback: rdp.audioPlayback.resolved(default: globalSettings.audioPlayback),
            clipboardPolicy: rdp.clipboardPolicy.resolved(default: globalSettings.clipboardPolicy),
            scrollDirection: rdp.scrollDirection.resolved(default: globalSettings.scrollDirection),
            reconnectPolicy: rdp.reconnectPolicy.resolved(default: globalSettings.reconnectPolicy),
            securityPolicy: rdp.securityPolicy
        )
    }
}

/// Zoom, pan, the live scroll inversion and a local audio mute are not part of
/// the handshake, so they live here and may change during a session. Changing
/// one never writes back to the profile unless the user explicitly saves it as
/// that connection's default.
public struct SessionRuntimeState: Hashable, Sendable {
    public var scale: InitialScale
    public var zoom: Double
    public var scrollDirection: ScrollDirection
    public var isLocallyMuted: Bool

    public init(
        scale: InitialScale = .fit,
        zoom: Double = 1.0,
        scrollDirection: ScrollDirection = .normal,
        isLocallyMuted: Bool = false
    ) {
        self.scale = scale
        self.zoom = zoom
        self.scrollDirection = scrollDirection
        self.isLocallyMuted = isLocallyMuted
    }

    public init(from configuration: EffectiveConnectionConfiguration) {
        self.init(
            scale: configuration.initialScale,
            zoom: 1.0,
            scrollDirection: configuration.scrollDirection,
            isLocallyMuted: false
        )
    }
}
