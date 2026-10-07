import Foundation
import Observation
import InputCore
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
    /// Why the server ended the session, when it did so on purpose.
    private(set) var endReason: RemoteEndReason?
    /// What protects the connection, as the server selected it.
    private(set) var transportSecurity: TransportSecurity?
    private(set) var pendingChallenge: SessionChallenge?
    /// Zoom, scale mode and the like: not part of the handshake, so they live
    /// here and may change while the session runs without writing back to the
    /// profile.
    private(set) var runtime: SessionRuntimeState
    private(set) var desktopSize: (width: Int, height: Int)?
    private(set) var supportsDynamicResolution = false
    /// The floating menu is open. Input is gated while it is, so a key held
    /// when it opened is released rather than left down behind the sheet.
    var isMenuPresented = false
    /// Non-nil while an automatic reconnect is waiting or running: the
    /// attempt number out of `reconnectSchedule.maximumAttempts`.
    private(set) var reconnectAttempt: Int?
    private var hadConnected = false
    private(set) var remoteHasText = false
    /// Shown as a toast; never contains clipboard text (docs/ui-flow.md 6.2).
    var clipboardMessage: String?
    private(set) var isTransferringClipboard = false
    /// The last text taken from the remote clipboard, kept only to recognise
    /// it coming back: pasting it straight back needs no new offer, because
    /// the remote still holds it (docs/architecture.md section 9).
    private var lastReceivedText: String?
    /// Whether the laptop deck - keyboard and trackpad on the lower half -
    /// is shown. Per session and not saved: whether it is wanted depends on
    /// how the device is being held, not on the host.
    var laptopDeckPreference: LaptopDeckPreference = .automatic
    /// Built once in `init`; never replaced, so observation is not needed on
    /// the property itself - the controller is observable on its own.
    @ObservationIgnored private(set) var softwareKeyboard: SoftwareKeyboardController!
    private var reconnectTask: Task<Void, Never>?
    private let reconnectSchedule = ReconnectSchedule()

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
        self.softwareKeyboard = SoftwareKeyboardController(
            mode: environment.globalSettings.softwareKeyboardMode,
            layout: configuration.keyboardLayout,
            canSend: { [weak self] in self?.acceptsInput ?? false },
            paste: configuration.clipboardPolicy.allowsSend
                ? { [weak self] text in Task { await self?.pasteToRemote(text) } }
                : nil,
            send: { [weak self] output in
                guard let sink = self?.inputSink else { return }
                switch output {
                case .key(let input): sink.send(input)
                case .unicode(let unit): sink.send(unicode: unit)
                }
            }
        )
    }

    /// From the menu: close it, then bring the keyboard up once the sheet is
    /// gone and the gate is open again.
    func showSoftwareKeyboard() {
        isMenuPresented = false
        softwareKeyboard.show()
    }

    nonisolated static func == (lhs: SessionWorkspaceModel, rhs: SessionWorkspaceModel) -> Bool {
        lhs.id == rhs.id
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    var statusText: String {
        if let reconnectAttempt {
            return String(localized: "再接続中 (\(reconnectAttempt)/\(reconnectSchedule.maximumAttempts))")
        }
        return Formatting.stateLabel(state)
    }

    var isBusy: Bool {
        state == .connecting || state == .reconnecting || reconnectAttempt != nil
    }

    var canRetry: Bool { state == .failed && reconnectAttempt == nil }

    /// The input gate, in one place: connected, focused, menu closed. The
    /// scene half is added by the view, which owns `scenePhase`.
    var acceptsInput: Bool { state.acceptsInput && isFocused && !isMenuPresented }

    /// Present only once the session has a desktop to draw. Until then the
    /// workspace shows its status rather than a black rectangle.
    var frameStore: LatestDesktopFrameStore? { desktop?.frameStore }

    /// Where the surface sends pointer input. Nil for a session that has no
    /// desktop, which is how a future terminal session gets a workspace
    /// without pretending to have a mouse.
    var inputSink: (any DesktopInputSink)? { desktop?.inputSink }

    var cursorStore: RemoteCursorStore? { desktop?.cursorStore }

    /// docs/input-design.md section 5: only the focused session may receive
    /// input. Mirrored from `SessionManager` by the environment.
    var isFocused: Bool { environment.focusedSessionID == id }

    /// docs/data-and-security.md section 4 asks for an audit display when a
    /// profile allows legacy RDP Security. Whether the server actually chose
    /// it is not reported by the bridge, so this says what was allowed.
    var allowsLegacySecurity: Bool { configuration.securityPolicy == .legacyExplicit }

    /// What to say over a desktop that is no longer live: the last frame
    /// stays on screen after the connection goes, so a drop, a reconnect in
    /// progress or a takeover would otherwise look like a frozen desktop.
    struct StateBanner: Equatable {
        var title: String
        var symbol: String
        var detail: String?
        var busy = false
        var offersReconnect = false
    }

    var stateBanner: StateBanner? {
        if reconnectAttempt != nil || state == .reconnecting {
            return StateBanner(
                title: statusText,
                symbol: "arrow.triangle.2.circlepath",
                detail: lastError.map(Formatting.errorLabel),
                busy: true
            )
        }
        switch state {
        case .failed:
            return StateBanner(
                title: String(localized: "接続が切れました"),
                symbol: "exclamationmark.triangle",
                detail: lastError.map(Formatting.errorLabel),
                offersReconnect: true
            )
        case .disconnected:
            return StateBanner(
                title: String(localized: "切断されました"),
                symbol: "rectangle.portrait.and.arrow.right",
                detail: endReason.map(Formatting.endReasonLabel),
                offersReconnect: true
            )
        default:
            return nil
        }
    }

    /// The server actually chose the legacy RDP Security Layer.
    var isUsingLegacySecurity: Bool { transportSecurity == .legacyRDP }

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
                endReason = nil
            }
            if state == .connecting { transportSecurity = nil }
            if state == .connected {
                lastError = nil
                hadConnected = true
                reconnectAttempt = nil
                if let desktop {
                    supportsDynamicResolution = await desktop.supportsDynamicResolution
                }
            }
            if state == .failed { scheduleReconnectIfNeeded() }
        case .userActionRequired(let challenge):
            pendingChallenge = challenge
            // A reconnect that needs the user is no longer automatic.
            reconnectAttempt = nil
        case .error(let error):
            lastError = error
            if state == .failed { scheduleReconnectIfNeeded() }
        case .transportSecurity(let security):
            transportSecurity = security
        case .endedByServer(let reason):
            // Shown instead of an error; the state is already on its way to
            // disconnected, which never reconnects on its own.
            endReason = reason
        case .clipboardChanged(let hasRemoteText):
            remoteHasText = hasRemoteText
            // A new remote copy: whatever was received before is no longer
            // what the remote holds.
            lastReceivedText = nil
        }
    }

    // MARK: - Clipboard

    var clipboardPolicy: ClipboardPolicy { configuration.clipboardPolicy }

    var canSendClipboard: Bool {
        clipboardPolicy.allowsSend && state == .connected
            && session is any ClipboardCapableSession && !isTransferringClipboard
    }

    var canReceiveClipboard: Bool {
        clipboardPolicy.allowsReceive && state == .connected && remoteHasText
            && session is any ClipboardCapableSession && !isTransferringClipboard
    }

    /// Local to remote: offer the text, wait for the server to take it, then
    /// close the menu and send the paste chord into the focused window. The
    /// chord is sent only here, on this explicit action.
    func pasteToRemote(_ text: String) async {
        guard canSendClipboard, let clipboard = session as? any ClipboardCapableSession else { return }
        isTransferringClipboard = true
        defer { isTransferringClipboard = false }
        do {
            if text != lastReceivedText || !remoteHasText {
                try await clipboard.offerClipboardText(text)
            }
            isMenuPresented = false
            // The chord needs the gate open again, which happens once the
            // sheet has gone and the surface has the keyboard back.
            for _ in 0..<50 where !acceptsInput {
                try? await Task.sleep(for: .milliseconds(20))
            }
            sendPasteChord()
            clipboardMessage = String(localized: "\(displayName) に貼り付けました")
        } catch {
            clipboardMessage = Self.clipboardFailureText(error)
        }
    }

    /// Remote to local: fetch on request, then write the pasteboard here on
    /// the main actor.
    func copyRemoteToDevice() async -> String? {
        guard canReceiveClipboard, let clipboard = session as? any ClipboardCapableSession else {
            return nil
        }
        isTransferringClipboard = true
        defer { isTransferringClipboard = false }
        do {
            let text = try await clipboard.fetchRemoteClipboardText()
            lastReceivedText = text
            clipboardMessage = String(localized: "\(displayName) からコピーしました")
            return text
        } catch {
            clipboardMessage = Self.clipboardFailureText(error)
            return nil
        }
    }

    private func sendPasteChord() {
        guard acceptsInput, let inputSink else { return }
        // Left Control + V as HID usages; the session maps them to its own
        // protocol. Down/up in order, so nothing is left held.
        let control: UInt16 = 0xE0
        let v: UInt16 = 0x19
        inputSink.send(KeyboardInput(usage: control, transition: .down))
        inputSink.send(KeyboardInput(usage: v, transition: .down))
        inputSink.send(KeyboardInput(usage: v, transition: .up))
        inputSink.send(KeyboardInput(usage: control, transition: .up))
    }

    private static func clipboardFailureText(_ error: Error) -> String {
        switch error as? ClipboardTransferError {
        case .unavailable: return String(localized: "クリップボードを使えません。接続設定の「クリップボード」で許可されているか、リモート側でクリップボードのリダイレクトが許可されているかを確認してください")
        case .timedOut: return String(localized: "リモートが応答しませんでした。少し待ってからもう一度試してください")
        case .unsupportedContent: return String(localized: "このテキストは送れません（大きすぎるか NUL を含みます）。長いテキストは分けて送ってください")
        case .nothingToCopy: return String(localized: "リモートにコピーされたテキストがありません。リモート側で先にコピーしてください")
        case .failed, .none: return String(localized: "クリップボードの転送に失敗しました。もう一度試してください")
        }
    }

    // MARK: - Audio

    var audioStream: PCMAudioStream? {
        (session as? any AudioCapableSession)?.audioSource as? PCMAudioStream
    }

    var isAudioMuted: Bool { runtime.isLocallyMuted || !configuration.audioPlayback }

    func setLocallyMuted(_ muted: Bool) {
        runtime.isLocallyMuted = muted
        environment.refreshAudioFocus()
    }

    // MARK: - Reconnect

    /// The failure and the error arrive as two events in either order, so
    /// both call this and the task itself is the guard against a second
    /// attempt for the same drop.
    private func scheduleReconnectIfNeeded() {
        guard reconnectTask == nil, state == .failed else { return }
        let attempt = (reconnectAttempt ?? 0) + 1
        guard let delay = reconnectSchedule.delay(
            beforeAttempt: attempt,
            after: lastError,
            policy: configuration.reconnectPolicy,
            hadConnected: hadConnected
        ) else {
            reconnectAttempt = nil
            return
        }
        reconnectAttempt = attempt
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil
            guard self.state == .failed else { return }
            await self.retry()
            // A failed attempt arrives as another `.failed`, which schedules
            // the next one; a success clears `reconnectAttempt`.
            if self.state == .failed { self.scheduleReconnectIfNeeded() }
        }
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = nil
    }

    // MARK: - Presentation

    func setScaleMode(_ mode: InitialScale) {
        runtime.scale = mode
    }

    /// Live, per-session, and never written back to the profile unless the
    /// user saves it as that connection's default.
    func setScrollDirection(_ direction: ScrollDirection) {
        runtime.scrollDirection = direction
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

    @ObservationIgnored private var displayScale: RemoteDisplayScale?

    /// How large Windows should draw. Resolved by the view, which knows the
    /// screen; the session sends it with the next layout, or at once.
    func setDisplayScale(_ scale: RemoteDisplayScale) {
        guard scale != displayScale else { return }
        displayScale = scale
        guard let desktop else { return }
        Task { await desktop.setDisplayScale(scale) }
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

    /// The 再接続 the user asks for. A failed session can try again in place;
    /// a disconnected one is finished - its state machine has no way back -
    /// so the workspace closes and the same profile connects anew.
    func reconnect() async {
        guard state == .disconnected else {
            await retry()
            return
        }
        let profileID = configuration.profileID
        await disconnect()
        guard let profileID,
              let profile = environment.profiles.first(where: { $0.id == profileID }) else { return }
        await environment.connect(to: profile)
    }

    func retry() async {
        if reconnectAttempt == nil { cancelReconnect() }
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
        await session.setVisibility(isFocused ? .focused : .background)
        await refresh()
        // docs/architecture.md section 10: a connection that died while the
        // app was away is found on the way back, and handled by policy.
        if state == .failed { scheduleReconnectIfNeeded() }
    }

    /// Leaves the workspace without disconnecting. docs/requirements.md SES-02
    /// keeps a foreground connection alive until the user disconnects
    /// explicitly, so going back to the list must not tear it down.
    func returnToList() {
        isMenuPresented = false
        softwareKeyboard.hide()
        environment.returnToList()
    }

    func disconnect() async {
        cancelReconnect()
        isMenuPresented = false
        softwareKeyboard.hide()
        resizeTask?.cancel()
        resizeTask = nil
        await session.disconnect(reason: .userRequested)
        eventTask?.cancel()
        eventTask = nil
        await environment.endSession(id)
    }
}

/// When the laptop deck takes the lower half of the screen.
enum LaptopDeckPreference: Hashable, CaseIterable {
    /// In a foldable's laptop posture: half open, hinge across the screen.
    case automatic
    case always
    case never

    func showsDeck(posture: HingePosture, isPortrait: Bool) -> Bool {
        switch self {
        case .automatic: return posture == .partiallyOpen && isPortrait
        case .always: return true
        case .never: return false
        }
    }
}
