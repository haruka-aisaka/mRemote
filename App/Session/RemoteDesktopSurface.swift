import SwiftUI
import SessionCore

/// Bridges the Metal surface into the SwiftUI workspace.
///
/// The view is built once per session and reconfigured afterwards: rebuilding
/// it would drop the desktop texture and force a full repaint on every
/// unrelated state change in the workspace.
struct RemoteDesktopSurface: UIViewRepresentable {
    let frameStore: LatestDesktopFrameStore
    let scaleMode: InitialScale
    let onRenderSizeChange: (Int, Int) -> Void
    let onDesktopSizeChange: (Int, Int) -> Void

    func makeUIView(context: Context) -> RemoteDesktopView {
        let view = RemoteDesktopView(frameStore: frameStore, scaleMode: scaleMode)
        view.onRenderSizeChange = onRenderSizeChange
        view.onDesktopSizeChange = onDesktopSizeChange
        return view
    }

    func updateUIView(_ view: RemoteDesktopView, context: Context) {
        view.onRenderSizeChange = onRenderSizeChange
        view.onDesktopSizeChange = onDesktopSizeChange
        view.setScaleMode(scaleMode)
    }

    static func dismantleUIView(_ view: RemoteDesktopView, coordinator: Coordinator) {
        // The store belongs to the session and outlives this view, so the
        // signal has to be dropped explicitly rather than left pointing at a
        // surface that is going away.
        view.detachFromFrameStore()
    }
}
