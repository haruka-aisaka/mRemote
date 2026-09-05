import Foundation

/// A session that presents a remote desktop.
///
/// docs/architecture.md section 4 keeps this separate from `RemoteSession` on
/// purpose: an SSH terminal is a session too, and it should not have to model
/// framebuffers to be one. Everything a desktop needs beyond lifecycle and
/// challenges lives here.
public protocol DesktopSession: RemoteSession {
    /// The data plane. Read directly by the renderer, never routed through
    /// `SessionManager`.
    nonisolated var frameStore: LatestDesktopFrameStore { get }

    /// The size the connection was negotiated at, before any dynamic resize.
    nonisolated var initialDesktopSize: (width: Int, height: Int) { get }

    /// True once the server has negotiated the display channel, which is the
    /// only condition under which asking for a different size does anything.
    var supportsDynamicResolution: Bool { get }

    /// Asks the server to resize the desktop. Debounced by the caller; the
    /// session drops the request when the display channel is absent rather
    /// than reporting an error, because a server without it is not broken.
    func requestDesktopSize(width: Int, height: Int) async
}
