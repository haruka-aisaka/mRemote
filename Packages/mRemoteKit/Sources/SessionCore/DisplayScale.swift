import Foundation

/// How large the server should draw: the Windows "Scale" setting, sent with
/// the connection and with every display layout.
///
/// Without it a server draws at 100%, and a desktop sized to a phone's
/// pixels - 2006x1428 in half of an iPhone Duo - has text too small to read.
public struct RemoteDisplayScale: Hashable, Sendable {
    /// MS-RDPBCGR 2.2.1.3.2.
    public static let minimumPercent = 100
    public static let maximumPercent = 500
    /// What the menu offers, as Windows' own Scale list does.
    public static let choices = [100, 125, 150, 175, 200, 250, 300]

    public let desktopPercent: Int

    public init(percent: Int) {
        desktopPercent = min(max(percent, Self.minimumPercent), Self.maximumPercent)
    }

    /// The device scale factor, which the protocol allows only as 100, 140 or
    /// 180: the largest that does not exceed the desktop scale.
    public var devicePercent: Int {
        if desktopPercent >= 180 { return 180 }
        if desktopPercent >= 140 { return 140 }
        return 100
    }

    /// One remote pixel per device pixel, drawn as large as the device draws
    /// its own interface: 300% on a 3x iPhone, 200% on a 2x iPad.
    public static func matching(screenScale: Double) -> RemoteDisplayScale {
        guard screenScale.isFinite, screenScale > 0 else { return RemoteDisplayScale(percent: 100) }
        return RemoteDisplayScale(percent: Int((screenScale * 100).rounded()))
    }

    public static let unscaled = RemoteDisplayScale(percent: 100)
}

/// The user's choice, stored as text: "auto" or a percentage.
public enum RemoteScalePreference: Hashable, Sendable, RawRepresentable {
    case automatic
    case fixed(Int)

    public init?(rawValue: String) {
        if rawValue == "auto" {
            self = .automatic
        } else if let percent = Int(rawValue) {
            self = .fixed(RemoteDisplayScale(percent: percent).desktopPercent)
        } else {
            return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .automatic: return "auto"
        case .fixed(let percent): return String(percent)
        }
    }

    public func resolved(screenScale: Double) -> RemoteDisplayScale {
        switch self {
        case .automatic: return .matching(screenScale: screenScale)
        case .fixed(let percent): return RemoteDisplayScale(percent: percent)
        }
    }
}

/// What happens to the remote resolution when part of the screen is given
/// to something else - the laptop deck on a folded device.
public enum FoldResolutionPolicy: String, Hashable, Sendable, CaseIterable {
    /// Ask the server for the size of the part that is left.
    case resizeToFit
    /// Keep asking for the whole screen and draw it smaller, so folding and
    /// unfolding never makes Windows rearrange its windows.
    case keepAndScale
    /// Always ask for the size of the part left above the deck, deck or no
    /// deck: the desktop keeps that shape, and without the deck it is drawn
    /// larger rather than rearranged.
    case lockToDeck
}
