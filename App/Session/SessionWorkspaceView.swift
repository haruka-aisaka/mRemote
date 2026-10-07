import SwiftUI
import SessionCore

/// Full screen, with one floating button. docs/ui-flow.md keeps the remote
/// desktop uncontested: no navigation bar, no persistent chrome, and the
/// status text only while there is no desktop to look at.
struct SessionWorkspaceView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var model: SessionWorkspaceModel
    @State private var toastText: String?
    @State private var hingePosture: HingePosture = .unavailable
    @State private var laptopChannel = LaptopDeckChannel()
    @AppStorage(LaptopDeckArrangement.storageKey)
    private var deckArrangement = LaptopDeckArrangement.keyboardAboveTrackpad

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            HingePostureReader { hingePosture = $0 }
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            SoftwareKeyboardHost(controller: model.softwareKeyboard)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            GeometryReader { proxy in
                split(in: proxy.size)
            }
            .ignoresSafeArea()
            privacyCover
        }
        .onAppear { showToast() }
        .onChange(of: model.clipboardMessage) { _, message in
            guard let message else { return }
            withAnimation { toastText = message }
            model.clipboardMessage = nil
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation { if toastText == message { toastText = nil } }
            }
        }
        // Naming the container must not hide what is inside it: the status
        // text and the floating menu have to stay individually reachable.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session-workspace")
        #if DEBUG
        // What the input gate is made of, for UI tests that drive a live host.
        .accessibilityValue(
            "state=\(model.state) focused=\(model.isFocused) menu=\(model.isMenuPresented) "
                + "phase=\(scenePhase) accepts=\(model.acceptsInput)"
        )
        #endif
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        // Only the presented session raises its challenge here; one waiting in
        // the background shows as 確認待ち in the list and the switcher.
        .sheet(item: challengeBinding) { identified in
            SessionChallengeSheet(
                challenge: identified.challenge,
                defaultUsername: model.configuration.account.username,
                defaultDomain: model.configuration.account.domain,
                onCredential: { username, domain, password, save in
                    Task {
                        await model.answerCredential(
                            username: username,
                            domain: domain,
                            password: password,
                            save: save
                        )
                    }
                },
                onTrust: { persist in
                    Task { await model.answer(persist ? .trustPersistently : .trustOnce) }
                },
                onCancel: {
                    Task { await model.answer(.cancel) }
                }
            )
        }
        .onChange(of: scenePhase, initial: false) { _, phase in
            Task {
                if phase == .active {
                    await model.sceneBecameActive()
                } else {
                    await model.sceneBecameInactive()
                }
            }
        }
    }

    /// The whole screen, or - with the laptop deck - the upper half for the
    /// desktop and the lower half for the deck. The hinge is in the middle,
    /// so that is where the split is.
    ///
    /// The desktop keeps its place in the hierarchy either way: the deck is
    /// added after it rather than the two being swapped between layouts,
    /// which would rebuild the surface and drop its texture.
    @ViewBuilder
    private func split(in size: CGSize) -> some View {
        let showsDeck = model.laptopDeckPreference.showsDeck(
            posture: hingePosture,
            isPortrait: size.height > size.width
        )
        VStack(spacing: 0) {
            ZStack {
                desktop(touchesDriveTrackpad: showsDeck && !deckArrangement.hasTrackpad)
                if !model.showsDesktop {
                    status
                }
                floatingMenu
                toast
            }
            .frame(height: showsDeck ? (size.height / 2).rounded() : size.height)
            .clipped()
            if showsDeck {
                LaptopDeck(
                    layout: model.configuration.keyboardLayout,
                    arrangement: deckArrangement,
                    channel: laptopChannel,
                    isInputEnabled: model.acceptsInput && scenePhase == .active
                )
                .transition(.move(edge: .bottom))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showsDeck)
        .onChange(of: showsDeck, initial: true) { _, shows in
            // The deck is the keyboard now; the system one would only cover it.
            if shows { model.softwareKeyboard.hide() }
        }
    }

    @ViewBuilder
    private func desktop(touchesDriveTrackpad: Bool) -> some View {
        if let frameStore = model.frameStore {
            RemoteDesktopSurface(
                frameStore: frameStore,
                cursorStore: model.cursorStore,
                inputSink: model.inputSink,
                scaleMode: model.runtime.scale,
                scrollDirection: model.runtime.scrollDirection,
                laptopChannel: laptopChannel,
                directTouchesDriveTrackpad: touchesDriveTrackpad,
                // Input is gated on both halves of docs/architecture.md
                // section 10: the session must be able to deliver it, and the
                // scene must be the one the user is looking at.
                // A third: the session must be the focused one, so a surface
                // left behind during a switch can never type into it.
                isInputEnabled: model.acceptsInput && scenePhase == .active,
                // The proxy owns the keyboard while the software keyboard is
                // up; the surface must not take it back on the next tap.
                suppressesKeyboardCapture: model.softwareKeyboard.isVisible,
                isInputTraceEnabled: environment.inputDiagnostics.isTraceRequested,
                onRenderSizeChange: { width, height in
                    model.renderSizeChanged(width: width, height: height)
                },
                onDesktopSizeChange: { width, height in
                    model.desktopSizeChanged(width: width, height: height)
                },
                onInputDiagnostics: { diagnostics in
                    environment.inputDiagnostics.update(diagnostics)
                }
            )
            .ignoresSafeArea()
            .opacity(model.showsDesktop ? 1 : 0)
        }
    }

    private var status: some View {
        VStack(spacing: 12) {
            Text(model.displayName)
                .font(.title2)
                .foregroundStyle(.white)
            Text(model.statusText)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.8))
                .accessibilityIdentifier("session-status")
            if model.isBusy {
                ProgressView().tint(.white)
            }
            if let error = model.lastError {
                Text(Formatting.errorLabel(error))
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 40)
            }
            if model.canRetry {
                Button("再接続") {
                    Task { await model.retry() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("session-retry")
            }
        }
    }

    /// docs/architecture.md section 10: the remote screen must not be what the
    /// app switcher snapshots. The cover is part of the view hierarchy rather
    /// than something applied on the way out, so there is no window in which
    /// the snapshot could be taken before it appears.
    @ViewBuilder
    private var privacyCover: some View {
        if scenePhase != .active {
            ZStack {
                Rectangle()
                    .fill(.ultraThickMaterial)
                    .ignoresSafeArea()
                VStack(spacing: 8) {
                    Image(systemName: "lock.display")
                        .font(.system(size: 44))
                    Text(model.displayName)
                        .font(.headline)
                    Text("接続は維持されています")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .transition(.opacity)
            .accessibilityIdentifier("session-privacy-cover")
        }
    }

    private var floatingMenu: some View {
        FloatingMenuButton {
            model.isMenuPresented = true
        }
        // On the button rather than the workspace: the workspace already
        // carries the challenge sheet, and two sheets on one view do not both
        // present.
        .sheet(isPresented: $model.isMenuPresented) {
            SessionMenuSheet(model: model)
                .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private var toast: some View {
        if let toastText {
            Text(toastText)
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
                .padding(.top, 24)
                .frame(maxHeight: .infinity, alignment: .top)
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
                .accessibilityIdentifier("session-toast")
        }
    }

    /// docs/ui-flow.md section 6: the session's name, briefly, when it is
    /// connected to or switched to.
    private func showToast() {
        withAnimation { toastText = "\(model.displayName) ・ \(model.statusText)" }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { toastText = nil }
        }
    }

    private var challengeBinding: Binding<IdentifiedChallenge?> {
        Binding(
            get: { model.pendingChallenge.map(IdentifiedChallenge.init) },
            // The sheet cannot be dismissed interactively, and every button on
            // it answers the challenge, so there is nothing to write back.
            set: { _ in }
        )
    }
}

/// `sheet(item:)` needs an Identifiable; the challenge ID already is the
/// identity, so this only adapts the shape.
struct IdentifiedChallenge: Identifiable {
    let challenge: SessionChallenge

    var id: ChallengeID { challenge.id }
}
