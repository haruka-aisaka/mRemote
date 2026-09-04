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

    private unowned let environment: AppEnvironment
    private let session: any RemoteSession
    /// Cancelled in `disconnect`, which is the only path that ends a session.
    /// There is no `deinit` cleanup because the model is main-actor isolated
    /// and `deinit` is not: the environment owns the model until the session
    /// is disconnected, so the task cannot outlive it.
    private var eventTask: Task<Void, Never>?

    init(
        environment: AppEnvironment,
        session: any RemoteSession,
        configuration: EffectiveConnectionConfiguration
    ) {
        self.environment = environment
        self.session = session
        self.configuration = configuration
        self.id = session.id
        self.displayName = configuration.displayName
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
    }

    private func apply(_ event: SessionControlEvent) {
        switch event {
        case .stateChanged(let state, _):
            self.state = state
            if state == .connected || state == .connecting {
                pendingChallenge = nil
            }
        case .userActionRequired(let challenge):
            pendingChallenge = challenge
        case .error(let error):
            lastError = error
        }
    }

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

    func retry() async {
        do {
            try await session.connect()
            await refresh()
        } catch {
            lastError = .internalFailure(detail: String(describing: error))
        }
    }

    /// Leaves the workspace without disconnecting. docs/requirements.md SES-02
    /// keeps a foreground connection alive until the user disconnects
    /// explicitly, so going back to the list must not tear it down.
    func returnToList() {
        environment.presentedSession = nil
    }

    func disconnect() async {
        eventTask?.cancel()
        eventTask = nil
        await session.disconnect(reason: .userRequested)
        await environment.endSession(id)
    }
}
