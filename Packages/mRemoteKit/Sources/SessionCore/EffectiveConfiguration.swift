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
    public let gateway: RDPGatewayConfiguration?
    public let sharedFolder: SharedFolder?
    public let remoteApp: RemoteAppConfiguration?
    public let redirectsMicrophone: Bool
    public let prefersH264: Bool

    public init(
        profileID: ProfileID?,
        displayName: String,
        endpoint: RemoteEndpoint,
        account: RemoteAccount,
        resolutionPolicy: ResolutionPolicy,
        initialScale: InitialScale,
        displayQuality: DisplayQuality,
        keyboardLayout: KeyboardLayoutPreference,
        audioPlayback: Bool,
        clipboardPolicy: ClipboardPolicy,
        scrollDirection: ScrollDirection,
        reconnectPolicy: ReconnectPolicy,
        securityPolicy: SecurityPolicy,
        gateway: RDPGatewayConfiguration? = nil,
        sharedFolder: SharedFolder? = nil,
        remoteApp: RemoteAppConfiguration? = nil,
        redirectsMicrophone: Bool = false,
        prefersH264: Bool = true
    ) {
        self.profileID = profileID
        self.displayName = displayName
        self.endpoint = endpoint
        self.account = account
        self.resolutionPolicy = resolutionPolicy
        self.initialScale = initialScale
        self.displayQuality = displayQuality
        self.keyboardLayout = keyboardLayout
        self.audioPlayback = audioPlayback
        self.clipboardPolicy = clipboardPolicy
        self.scrollDirection = scrollDirection
        self.reconnectPolicy = reconnectPolicy
        self.securityPolicy = securityPolicy
        self.gateway = gateway
        self.sharedFolder = sharedFolder
        self.remoteApp = remoteApp
        self.redirectsMicrophone = redirectsMicrophone
        self.prefersH264 = prefersH264
    }

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
            securityPolicy: rdp.securityPolicy,
            gateway: rdp.gateway,
            sharedFolder: rdp.sharedFolder,
            remoteApp: rdp.remoteApp,
            redirectsMicrophone: rdp.redirectsMicrophone,
            prefersH264: rdp.prefersH264
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
    /// Starts as the connection's setting; the session menu changes it for
    /// this session only.
    public var resolution: ResolutionPolicy

    public init(
        scale: InitialScale = .fit,
        zoom: Double = 1.0,
        scrollDirection: ScrollDirection = .normal,
        isLocallyMuted: Bool = false,
        resolution: ResolutionPolicy = .adaptive
    ) {
        self.scale = scale
        self.zoom = zoom
        self.scrollDirection = scrollDirection
        self.isLocallyMuted = isLocallyMuted
        self.resolution = resolution
    }

    public init(from configuration: EffectiveConnectionConfiguration) {
        self.init(
            scale: configuration.initialScale,
            zoom: 1.0,
            scrollDirection: configuration.scrollDirection,
            isLocallyMuted: false,
            resolution: configuration.resolutionPolicy
        )
    }
}
