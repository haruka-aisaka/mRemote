import SwiftUI
import InputCore
import SessionCore

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
    /// False while the scene is inactive or the session is not connected. The
    /// view releases whatever it thinks is held when this goes false, which is
    /// what keeps a button from staying down on the server.
    let isInputEnabled: Bool
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
        view.onRenderSizeChange = onRenderSizeChange
        view.onDesktopSizeChange = onDesktopSizeChange
        view.onInputDiagnostics = onInputDiagnostics
        view.inputSink = inputSink
        view.setInputTraceEnabled(isInputTraceEnabled)
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
