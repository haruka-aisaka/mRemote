import CoreGraphics
import SessionCore

/// What three and four fingers swiping across a trackpad do on a Mac host.
enum MacSwipeGestureMode: String, CaseIterable {
    /// The shortcut that does the same when the swipe is done: ⌃← / ⌃→
    /// between Spaces, ⌃↑ Mission Control, ⌃↓ App Exposé. Works on any Mac
    /// that keeps those shortcuts.
    case shortcuts
    /// The Dock's own swipe, the screen following the fingers as on a Mac's
    /// trackpad. Rides on events macOS does not document.
    case followFingers
    /// Three and four fingers scroll, as two do.
    case off

    static let storageKey = "mac-swipe-gesture-mode"
}

/// Whether two fingers pinching, turning and double tapping go to a Mac host
/// as those gestures. Off, a pinch on the desktop zooms this view instead.
enum MacPinchGestures {
    static let storageKey = "mac-pinch-gestures"
}

/// The direction the fingers moved in a swipe.
enum SwipeDirection: Equatable {
    case left, right, up, down

    /// The Mac's shortcut for this swipe: fingers moving left bring in the
    /// Space to the right, as on a trackpad with natural direction.
    var macShortcut: (key: UInt16, label: String) {
        switch self {
        case .left: return (0x4F, "⌃→")
        case .right: return (0x50, "⌃←")
        case .up: return (0x52, "⌃↑")
        case .down: return (0x51, "⌃↓")
        }
    }
}

/// What the host takes from a trackpad beyond moving the pointer, clicking
/// and wheel scrolling. All off for anything but a Mac with the extensions.
struct TrackpadMacGestures: Equatable {
    /// Two-finger scrolling as pixel deltas with phases: smooth, and what
    /// Safari reads a swipe between pages from.
    var preciseScroll = false
    /// Pinch, rotate and two-finger double tap as the Mac's gestures.
    var pinch = false
    var swipes = MacSwipeGestureMode.off

    static let none = TrackpadMacGestures()
}
