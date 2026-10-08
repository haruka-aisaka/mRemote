import Foundation

/// What kind of computer a connection reaches.
///
/// Every RDP server speaks plain RDP, and that is all a `.standard`
/// connection uses. A `.macOS` connection also offers the Mac RDP eXtensions
/// (the MACRDPX channel of macos-rdp-server): when the server takes them up,
/// keys travel as Mac keys with their exact modifiers, the pointer and
/// trackpad scrolling travel natively, and the stream rate can be chosen.
/// A server that does not know the channel never opens it, and the
/// connection simply stays plain RDP.
public enum RemotePlatform: String, Hashable, Sendable, Codable, CaseIterable {
    case standard
    case macOS
}

/// How much of the network the desktop stream may use, for a Mac server.
public enum StreamQuality: String, Hashable, Sendable, Codable, CaseIterable {
    /// High on an unmetered network, low on cellular or Low Data Mode.
    case automatic
    case high
    case balanced
    case low

    /// The frame rate and bit rate asked of the server.
    public func streamRequest(onConstrainedNetwork constrained: Bool) -> (framesPerSecond: Int, bitrateKbps: Int) {
        switch self {
        case .automatic:
            return (constrained ? StreamQuality.low : StreamQuality.high)
                .streamRequest(onConstrainedNetwork: constrained)
        case .high: return (60, 20_000)
        case .balanced: return (30, 8_000)
        case .low: return (15, 1_500)
        }
    }
}

/// The Mac extensions both ends agreed on. Values mirror MRX_CAP_* of
/// macrdpx.h, so the RDP layer can pass them through unchanged.
public struct MacExtensionFeatures: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let macKeys = MacExtensionFeatures(rawValue: 1 << 0)
    public static let pointer = MacExtensionFeatures(rawValue: 1 << 1)
    public static let preciseScroll = MacExtensionFeatures(rawValue: 1 << 2)
    public static let streamConfig = MacExtensionFeatures(rawValue: 1 << 3)
    public static let inputSource = MacExtensionFeatures(rawValue: 1 << 4)
    public static let cursorAlpha = MacExtensionFeatures(rawValue: 1 << 5)

    public static let all: MacExtensionFeatures = [
        .macKeys, .pointer, .preciseScroll, .streamConfig, .inputSource, .cursorAlpha,
    ]
}

/// What the session menu shows about a Mac server.
public struct MacExtensionStatus: Hashable, Sendable {
    public var serverName: String
    public var features: MacExtensionFeatures
    public var framesPerSecond: Int?
    public var bitrateKbps: Int?
    /// 200 when the server draws at Retina density.
    public var scalePercent: Int?
    /// The server's keyboard input source, and whether it types ASCII.
    public var inputSourceID: String?
    public var isASCIICapable: Bool?
    public var quality: StreamQuality

    public init(
        serverName: String,
        features: MacExtensionFeatures,
        quality: StreamQuality,
        framesPerSecond: Int? = nil,
        bitrateKbps: Int? = nil,
        scalePercent: Int? = nil,
        inputSourceID: String? = nil,
        isASCIICapable: Bool? = nil
    ) {
        self.serverName = serverName
        self.features = features
        self.quality = quality
        self.framesPerSecond = framesPerSecond
        self.bitrateKbps = bitrateKbps
        self.scalePercent = scalePercent
        self.inputSourceID = inputSourceID
        self.isASCIICapable = isASCIICapable
    }
}

/// A session that may have agreed the Mac extensions with its server.
public protocol MacExtensionCapableSession: RemoteSession {
    /// Nil until (and unless) the server takes the extensions up.
    var macExtensionStatus: MacExtensionStatus? { get async }
    /// Asks the server for this stream quality, for this session only.
    func setStreamQuality(_ quality: StreamQuality) async
}

/// One Mac key, as AppKit reported it: a virtual key code (kVK_*) and the
/// full NSEvent modifier flags after the event, left/right bits included.
public struct MacKeyInput: Hashable, Sendable {
    public let keyCode: UInt16
    public let transition: InputTransition
    public let isRepeat: Bool
    public let modifierFlags: UInt64

    public init(keyCode: UInt16, transition: InputTransition, isRepeat: Bool = false, modifierFlags: UInt64) {
        self.keyCode = keyCode
        self.transition = transition
        self.isRepeat = isRepeat
        self.modifierFlags = modifierFlags
    }
}

/// One scroll event as AppKit reported it (NSEvent scrollingDelta*, phase
/// and momentumPhase raw values).
public struct MacScrollInput: Hashable, Sendable {
    public let deltaX: Double
    public let deltaY: Double
    /// Pixel deltas from a trackpad or Magic Mouse; false for a wheel's lines.
    public let isPrecise: Bool
    public let phase: UInt8
    public let momentumPhase: UInt8
    public let isDirectionInvertedFromDevice: Bool
    public let modifierFlags: UInt64

    public init(
        deltaX: Double,
        deltaY: Double,
        isPrecise: Bool,
        phase: UInt8,
        momentumPhase: UInt8,
        isDirectionInvertedFromDevice: Bool,
        modifierFlags: UInt64
    ) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.isPrecise = isPrecise
        self.phase = phase
        self.momentumPhase = momentumPhase
        self.isDirectionInvertedFromDevice = isDirectionInvertedFromDevice
        self.modifierFlags = modifierFlags
    }
}
