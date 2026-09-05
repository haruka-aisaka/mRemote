import Foundation
import Observation
import SessionCore

/// Drives the full-screen session: it mirrors the session's authoritative
/// state into something a view can render, and turns the floating menu's
/// actions into session calls.
///
/// It never holds frames or input. Those go directly between the surface and
/// the session, because routing them through an observable object would put
/// every frame on the main actor.
@MainActor
@Observable
final class SessionWorkspaceModel: Identifiable, Hashable {
    nonisolated let id: SessionID
    let displayName: String
    let configuration: EffectiveConnectionConfiguration

    private(set) var state: SessionState = .idle
    private(set) var lastError: RemoteSessionError?
    private(set) var pendingChallenge: SessionChallenge?
    /// Zoom, scale mode and the like: not part of the handshake, so they live
    /// here and may change while the session runs without writing back to the
    /// profile.
    private(set) var runtime: SessionRuntimeState
    private(set) var desktopSize: (width: Int, height: Int)?
    private(set) var supportsDynamicResolution = false

    private unowned let environment: AppEnvironment
    private let session: any RemoteSession
    /// Nil for a session that draws no desktop. Phase 8's SSH session is
    /// exactly that case, and the workspace has to render something else
    /// rather than assume a framebuffer.
    private let desktop: (any DesktopSession)?
    /// Cancelled in `disconnect`, which is the only path that ends a session.
    /// There is no `deinit` cleanup because the model is main-actor isolated
    /// and `deinit` is not: the environment owns the model until the session
    /// is disconnected, so the task cannot outlive it.
    private var eventTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var lastRequestedRenderSize: (width: Int, height: Int)?

    /// A rotation or a Stage Manager resize arrives as a burst of layout
    /// passes. Asking the server to resize on each one would renegotiate the
    /// desktop several times for one gesture.
    private static let resizeDebounce = Duration.milliseconds(500)

    init(
        environment: AppEnvironment,
        session: any RemoteSession,
        configuration: EffectiveConnectionConfiguration
    ) {
        self.environment = environment
        self.session = session
        self.desktop = session as? any DesktopSession
        self.configuration = configuration
        self.id = session.id
        self.displayName = configuration.displayName
        self.runtime = SessionRuntimeState(from: configuration)
    }

    nonisolated static func == (lhs: SessionWorkspaceModel, rhs: SessionWorkspaceModel) -> Bool {
        lhs.id == rhs.id
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var statusText: String { Formatting.stateLabel(state) }

    var isBusy: Bool { state == .connecting || state == .reconnecting }

    var canRetry: Bool { state == .failed }

    /// Present only once the session has a desktop to draw. Until then the
    /// workspace shows its status rather than a black rectangle.
    var frameStore: LatestDesktopFrameStore? { desktop?.frameStore }

    var showsDesktop: Bool { desktop != nil && (state == .connected || desktopSize != nil) }

    func start() async {
        let stream = await session.controlEvents()
        eventTask = Task { [weak self] in
            for await event in stream {
                await self?.apply(event)
            }
        }
        do {
            try await session.connect()
        } catch {
            lastError = .internalFailure(detail: String(describing: error))
        }
        // Events arrive asynchronously, so read the authoritative state once
        // connect returns rather than waiting for the stream to catch up.
        await refresh()
    }

    /// Re-reads state from the session. Used after connect and after a
    /// challenge answer; the session, not this model, is the source of truth.
    func refresh() async {
        state = await session.state
        pendingChallenge = await session.pendingChallenge
        if let desktop {
            supportsDynamicResolution = await desktop.supportsDynamicResolution
        }
    }

    private func apply(_ event: SessionControlEvent) async {
        switch event {
        case .stateChanged(let state, _):
            self.state = state
            if state == .connected || state == .connecting {
                pendingChallenge = nil
            }
            if state == .connected {
                lastError = nil
                if let desktop {
                    supportsDynamicResolution = await desktop.supportsDynamicResolution
                }
            }
        case .userActionRequired(let challenge):
            pendingChallenge = challenge
        case .error(let error):
            lastError = error
        }
    }

    // MARK: - Presentation

    func setScaleMode(_ mode: InitialScale) {
        runtime.scale = mode
    }

    /// The surface reports its drawable size in pixels. A server that
    /// negotiated the display channel is asked to match it; one that did not
    /// keeps its own size and the surface scales locally, which is why this is
    /// not an error path.
    func renderSizeChanged(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        guard lastRequestedRenderSize?.width != width
                || lastRequestedRenderSize?.height != height else { return }
        lastRequestedRenderSize = (width, height)

        resizeTask?.cancel()
        guard let desktop else { return }
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.resizeDebounce)
            guard !Task.isCancelled else { return }
            await desktop.requestDesktopSize(width: width, height: height)
            await self?.refresh()
        }
    }

    func desktopSizeChanged(width: Int, height: Int) {
        desktopSize = (width, height)
    }

    var desktopSizeText: String? {
        guard let desktopSize else { return nil }
        return "\(desktopSize.width)×\(desktopSize.height)"
    }

    // MARK: - Challenges

    func answer(_ response: ChallengeResponse) async {
        guard let challenge = pendingChallenge else { return }
        pendingChallenge = nil
        do {
            try await session.respond(to: challenge.id, with: response)
            await refresh()
        } catch {
            // A stale answer is reported rather than retried: the attempt it
            // belonged to is already over.
            lastError = .internalFailure(detail: String(describing: error))
        }
    }

    /// Saving happens here rather than inside the session because a profile
    /// that has never stored a password has no Keychain reference yet, and
    /// creating one is a change to the profile document.
    func answerCredential(
        username: String,
        domain: String?,
        password: String,
        save: Bool
    ) async {
        if save, !password.isEmpty, let profileID = configuration.profileID {
            await environment.persistCredential(
                profileID: profileID,
                username: username,
                domain: domain,
                password: password
            )
        }
        await answer(.credential(
            username: username,
            domain: domain,
            password: password,
            save: false
        ))
    }

    func retry() async {
        do {
            try await session.connect()
            await refresh()
        } catch {
            lastError = .internalFailure(detail: String(describing: error))
        }
    }

    // MARK: - Lifecycle

    /// docs/architecture.md section 10: an inactive scene releases input and
    /// hides the remote screen from the app switcher. The connection itself is
    /// left alone - losing focus is not a reason to drop it.
    func sceneBecameInactive() async {
        await session.setVisibility(.background)
    }

    func sceneBecameActive() async {
        await session.setVisibility(.focused)
        await refresh()
    }

    /// Leaves the workspace without disconnecting. docs/requirements.md SES-02
    /// keeps a foreground connection alive until the user disconnects
    /// explicitly, so going back to the list must not tear it down.
    func returnToList() {
        environment.presentedSession = nil
    }

    func disconnect() async {
        resizeTask?.cancel()
        resizeTask = nil
        await session.disconnect(reason: .userRequested)
        eventTask?.cancel()
        eventTask = nil
        await environment.endSession(id)
    }
}
