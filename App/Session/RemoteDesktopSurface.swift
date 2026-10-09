import SwiftUI
import InputCore
import SessionCore

/// What a finger on the desktop does. A mouse or a trackpad drives the
/// remote pointer whichever this is; pinch always zooms the local view.
enum TouchPointerMode: String, CaseIterable {
    /// Taps and drags act where the finger is, as on a touch screen: one
    /// finger as a touch on a host that takes touches, the mouse otherwise.
    /// (A setting saved as the former `touch` mode, every finger to
    /// Windows, reads as this: `@AppStorage` falls back to the default.)
    case direct
    /// The desktop is a trackpad: the finger moves the pointer by travel.
    case trackpad
    /// Touch only pans and zooms the local view; nothing reaches the host.
    case viewport

    static let storageKey = "touch-pointer-mode"
}

/// Whether Apple Pencil reaches Windows as a pen, with pressure and tilt,
/// rather than as a finger. Kept on the device.
enum PencilInput {
    static let storageKey = "pencil-as-pen"
}

/// Whether the desktop is lifted above the software keyboard so the pointer
/// stays in sight. Kept on the device, for every session.
enum KeyboardPointerFollowing {
    static let storageKey = "follows-pointer-above-keyboard"
}

/// Bridges the Metal surface into the SwiftUI workspace.
///
/// The view is built once per session and reconfigured afterwards: rebuilding
/// it would drop the desktop texture and force a full repaint on every
/// unrelated state change in the workspace.
struct RemoteDesktopSurface: UIViewRepresentable {
    let frameStore: LatestDesktopFrameStore
    let cursorStore: RemoteCursorStore?
    let inputSink: (any DesktopInputSink)?
    let scaleMode: InitialScale
    let scrollDirection: ScrollDirection
    /// Where the laptop deck finds this surface, when there is one.
    let laptopChannel: LaptopDeckChannel?
    let touchMode: TouchPointerMode
    var followsPointerAboveKeyboard = true
    var sendsPencilAsPen = true
    /// Points to ask the server for instead of the surface's own size.
    let renderSizeOverride: CGSize?
    /// Fed with every frame and pointer move, for a monitor to draw.
    var mirror: DesktopMirror?
    /// This screen's part of a desktop spread over a monitor as well.
    var primaryRegion: DesktopSpan?
    /// False while the scene is inactive or the session is not connected. The
    /// view releases whatever it thinks is held when this goes false, which is
    /// what keeps a button from staying down on the server.
    let isInputEnabled: Bool
    let suppressesKeyboardCapture: Bool
    let isInputTraceEnabled: Bool
    let onRenderSizeChange: (Int, Int) -> Void
    let onDesktopSizeChange: (Int, Int) -> Void
    let onInputDiagnostics: (InputDiagnostics) -> Void

    func makeUIView(context: Context) -> RemoteDesktopView {
        let view = RemoteDesktopView(
            frameStore: frameStore,
            cursorStore: cursorStore,
            scaleMode: scaleMode,
            scrollDirection: scrollDirection
        )
        configure(view)
        return view
    }

    func updateUIView(_ view: RemoteDesktopView, context: Context) {
        configure(view)
        view.setScaleMode(scaleMode)
    }

    private func configure(_ view: RemoteDesktopView) {
        laptopChannel?.surface = view
        view.setTouchMode(touchMode)
        view.setFollowsPointerAboveKeyboard(followsPointerAboveKeyboard)
        view.sendsPencilAsPen = sendsPencilAsPen
        view.setRenderSizeOverride(renderSizeOverride)
        view.mirror = mirror
        view.setPrimaryRegion(primaryRegion?.primary)
        view.onRenderSizeChange = onRenderSizeChange
        view.onDesktopSizeChange = onDesktopSizeChange
        view.onInputDiagnostics = onInputDiagnostics
        view.inputSink = inputSink
        view.setInputTraceEnabled(isInputTraceEnabled)
        view.setKeyboardCaptureSuppressed(suppressesKeyboardCapture)
        view.setScrollDirection(scrollDirection)
        view.setInputEnabled(isInputEnabled)
    }

    static func dismantleUIView(_ view: RemoteDesktopView, coordinator: Coordinator) {
        // The store belongs to the session and outlives this view, so the
        // signal has to be dropped explicitly rather than left pointing at a
        // surface that is going away. Held buttons and keys go with it: the
        // surface is gone, but the session may still be connected, and a
        // modifier left down would turn every later keystroke into a
        // shortcut.
        view.releaseHeldButtons()
        view.releaseHeldKeys(reason: .surfaceRemoved)
        view.detachFromFrameStore()
    }
}
