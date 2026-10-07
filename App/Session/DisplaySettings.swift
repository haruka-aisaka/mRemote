import SessionCore

// Device-wide display choices, stored with @AppStorage: how large Windows
// draws, and whether folding changes the remote resolution. They depend on
// the device in hand rather than on the host, so they are not profile fields.

extension RemoteScalePreference {
    static let storageKey = "remote-display-scale"
}

extension FoldResolutionPolicy {
    static let storageKey = "fold-resolution-policy"
}

/// Whether the desktop keeps clear of what the screen does not fully show -
/// the Dynamic Island or notch, the rounded corners, the home indicator. The
/// insets come from the system for whichever device and rotation is in hand.
enum DesktopSafeAreaPolicy: String, CaseIterable {
    /// The desktop is fitted inside the safe area, and the rest stays black.
    case avoid
    /// Edge to edge: more pixels, some of them under the island or a corner.
    case fullScreen

    static let storageKey = "desktop-safe-area"
}
