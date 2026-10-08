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

    /// The other half of the data plane. Written directly by the surface, for
    /// the same reason frames are not routed through the actor.
    nonisolated var inputSink: any DesktopInputSink { get }

    /// The pointer image the server wants shown. Data plane, like frames.
    nonisolated var cursorStore: RemoteCursorStore { get }

    /// The size the connection was negotiated at, before any dynamic resize.
    nonisolated var initialDesktopSize: (width: Int, height: Int) { get }

    /// True once the server has negotiated the display channel, which is the
    /// only condition under which asking for a different size does anything.
    var supportsDynamicResolution: Bool { get }

    /// Asks the server to resize the desktop. Debounced by the caller; the
    /// session drops the request when the display channel is absent rather
    /// than reporting an error, because a server without it is not broken.
    func requestDesktopSize(width: Int, height: Int) async

    /// How large the server should draw. Applied with the next layout the
    /// session can send - which it sends at once if only the scale changed.
    func setDisplayScale(_ scale: RemoteDisplayScale) async

    /// Two monitors side by side: this one, and a second to its right drawn
    /// at 100%. One desktop spans both, `primary.width + secondary.width`
    /// wide. Nil for the second is the same as `requestDesktopSize`.
    func requestDesktopLayout(
        primary: (width: Int, height: Int),
        secondary: (width: Int, height: Int)?
    ) async
}

extension DesktopSession {
    /// A session that cannot tell its server how large to draw ignores it.
    public func setDisplayScale(_ scale: RemoteDisplayScale) async {}

    /// A session with one monitor only asks for the first.
    public func requestDesktopLayout(
        primary: (width: Int, height: Int),
        secondary: (width: Int, height: Int)?
    ) async {
        await requestDesktopSize(width: primary.width, height: primary.height)
    }
}
