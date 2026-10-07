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
