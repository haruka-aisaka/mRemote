import Foundation

/// The values every `inherit` resolves against. Defaults live here and in the
/// schema migration, never spread across the settings screens.
public struct GlobalSettings: Hashable, Sendable, Codable {
    public var resolutionPolicy: ResolutionPolicy
    public var initialScale: InitialScale
    public var displayQuality: DisplayQuality
    public var keyboardLayout: KeyboardLayoutPreference
    public var audioPlayback: Bool
    public var clipboardPolicy: ClipboardPolicy
    public var scrollDirection: ScrollDirection
    public var reconnectPolicy: ReconnectPolicy

    public init(
        resolutionPolicy: ResolutionPolicy = .adaptive,
        initialScale: InitialScale = .fit,
        displayQuality: DisplayQuality = .automatic,
        keyboardLayout: KeyboardLayoutPreference = .japanese,
        audioPlayback: Bool = true,
        clipboardPolicy: ClipboardPolicy = .bidirectional,
        scrollDirection: ScrollDirection = .normal,
        reconnectPolicy: ReconnectPolicy = .automatic
    ) {
        self.resolutionPolicy = resolutionPolicy
        self.initialScale = initialScale
        self.displayQuality = displayQuality
        self.keyboardLayout = keyboardLayout
        self.audioPlayback = audioPlayback
        self.clipboardPolicy = clipboardPolicy
        self.scrollDirection = scrollDirection
        self.reconnectPolicy = reconnectPolicy
    }

    public static let `default` = GlobalSettings()
}
