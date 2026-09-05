import SwiftUI
import SessionCore

/// Full screen, with one floating button. docs/ui-flow.md keeps the remote
/// desktop uncontested: no navigation bar, no persistent chrome, and the
/// status text only while there is no desktop to look at.
struct SessionWorkspaceView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var model: SessionWorkspaceModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            desktop
            if !model.showsDesktop {
                status
            }
            floatingMenu
            privacyCover
        }
        // Naming the container must not hide what is inside it: the status
        // text and the floating menu have to stay individually reachable.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session-workspace")
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
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

    @ViewBuilder
    private var desktop: some View {
        if let frameStore = model.frameStore {
            RemoteDesktopSurface(
                frameStore: frameStore,
                scaleMode: model.runtime.scale,
                onRenderSizeChange: { width, height in
                    model.renderSizeChanged(width: width, height: height)
                },
                onDesktopSizeChange: { width, height in
                    model.desktopSizeChanged(width: width, height: height)
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
        VStack {
            Spacer()
            HStack {
                Spacer()
                Menu {
                    Picker("表示倍率", selection: scaleBinding) {
                        Text("画面に合わせる").tag(InitialScale.fit)
                        Text("100%").tag(InitialScale.oneToOne)
                    }
                    .accessibilityIdentifier("session-scale-picker")

                    if let size = model.desktopSizeText {
                        Section("リモート解像度") {
                            Text(model.supportsDynamicResolution ? "\(size)（可変）" : size)
                        }
                    }

                    Button {
                        model.returnToList()
                    } label: {
                        Label("接続先一覧へ戻る", systemImage: "list.bullet")
                    }
                    .accessibilityIdentifier("session-return-to-list")

                    Button(role: .destructive) {
                        Task { await model.disconnect() }
                    } label: {
                        Label("切断", systemImage: "xmark.circle")
                    }
                    .accessibilityIdentifier("session-disconnect")
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.system(size: 44))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .accessibilityIdentifier("session-menu-button")
                .padding(24)
            }
        }
    }

    private var scaleBinding: Binding<InitialScale> {
        Binding(
            get: { model.runtime.scale },
            set: { model.setScaleMode($0) }
        )
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
