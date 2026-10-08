import SwiftUI
import UIKit
import InputCore
import SessionCore

/// The floating button's menu (docs/ui-flow.md section 6.1).
///
/// Opening it closes the input gate - `SessionWorkspaceModel.acceptsInput` -
/// so whatever was held is released before the sheet appears, and closing it
/// gives the keyboard back to the surface.
struct SessionMenuSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: SessionWorkspaceModel
    @State private var confirmingDisconnect = false
    @AppStorage(LaptopDeckArrangement.storageKey)
    private var deckArrangement = LaptopDeckArrangement.keyboardAboveTrackpad
    @AppStorage(TouchPointerMode.storageKey) private var touchMode = TouchPointerMode.direct
    @AppStorage(LaptopDeckPreference.storageKey) private var deckPreference = LaptopDeckPreference.automatic

    private var touchModeHint: String {
        switch touchMode {
        case .direct:
            String(localized: "タップでクリック、長押しで右クリック、なぞるとドラッグ、2 本指でスクロール。ピンチで拡大し、拡大中はピンチしたまま動かすと表示が動きます。")
        case .trackpad:
            String(localized: "なぞるとポインターが動きます。タップでクリック、2 本指タップで右クリック、2 本指でスクロール、押さえてから動かすとドラッグ。")
        case .viewport:
            String(localized: "タッチは Windows へ送りません。1 本指で表示を動かし、ピンチで拡大、ダブルタップで全体表示と 100% を切り替えます。")
        }
    }
    @AppStorage(CapsLockRole.storageKey) private var capsLockRole = CapsLockRole.capsLock
    @AppStorage(LaptopKeyboardPlatform.storageKey) private var deckPlatform = LaptopKeyboardPlatform.windows
    @AppStorage(RemoteScalePreference.storageKey)
    private var scalePreference = RemoteScalePreference.automatic
    @AppStorage(FoldResolutionPolicy.storageKey)
    private var foldPolicy = FoldResolutionPolicy.resizeToFit
    @AppStorage(LaptopDeckArrangement.trackpadButtonsStorageKey) private var showsTrackpadButtons = true
    @AppStorage(DesktopSafeAreaPolicy.storageKey)
    private var safeAreaPolicy = DesktopSafeAreaPolicy.avoid
    @AppStorage(LaptopDeckPlacement.storageKey) private var deckPlacement = LaptopDeckPlacement.docked
    @AppStorage(KeyboardPointerFollowing.storageKey) private var followsPointerAboveKeyboard = true
    @AppStorage(LaptopDeckArrangement.splitInLandscapeStorageKey) private var splitsDeckInLandscape = false
    @AppStorage(LaptopDeckPreference.foldedLandscapeStorageKey) private var showsDeckFoldedInLandscape = false

    private var canFloatDeck: Bool {
        UIDevice.current.userInterfaceIdiom == .pad || model.deviceHasHinge
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(model.displayName).font(.headline)
                        Spacer()
                        SessionStateBadge(state: model.state, statusText: model.statusText)
                    }
                    if let security = model.transportSecurity {
                        LabeledContent("通信の保護", value: Formatting.transportLabel(security))
                            .accessibilityIdentifier("session-transport-security")
                    }
                    // docs/data-and-security.md section 4: the audit display.
                    // Strong when the server actually chose legacy security,
                    // a note when it was only allowed.
                    if model.isUsingLegacySecurity {
                        Label(
                            String(localized: "この接続は古い RDP セキュリティで通信しています。暗号は弱く、サーバーの確認もできません。"),
                            systemImage: "exclamationmark.shield"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("session-legacy-security")
                    } else if model.allowsLegacySecurity {
                        Label(
                            model.transportSecurity == nil
                                ? String(localized: "古い RDP セキュリティを許可した接続先です。")
                                : String(localized: "古い RDP セキュリティを許可した接続先ですが、この接続では使われていません。"),
                            systemImage: "shield.lefthalf.filled"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("session-legacy-security")
                    }
                }

                Section {
                    Button {
                        model.returnToList()
                    } label: {
                        Label("接続先一覧へ戻る（接続を維持）", systemImage: "list.bullet")
                    }
                    .accessibilityIdentifier("session-return-to-list")

                    if model.canRetry || model.state == .disconnected {
                        Button {
                            dismiss()
                            Task { await model.reconnect() }
                        } label: {
                            Label("再接続", systemImage: "arrow.clockwise")
                        }
                        .accessibilityIdentifier("session-reconnect")
                    }

                    Button(role: .destructive) {
                        confirmingDisconnect = true
                    } label: {
                        Label("このセッションを切断", systemImage: "xmark.circle")
                    }
                    .accessibilityIdentifier("session-disconnect")
                }
                if environment.runningSessions.count > 1 {
                    Section("セッションを切り替える") {
                        ForEach(environment.runningSessions) { session in
                            Button {
                                environment.switchTo(session)
                            } label: {
                                HStack {
                                    Image(systemName: session.id == model.id
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(session.id == model.id ? Color.accentColor : .secondary)
                                    Text(session.displayName)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    SessionStateBadge(state: session.state, statusText: session.statusText)
                                }
                            }
                            .disabled(session.id == model.id)
                            .accessibilityIdentifier("switch-to-\(session.displayName)")
                        }
                    }
                }

                Section {
                    Button {
                        model.showSoftwareKeyboard()
                    } label: {
                        Label("キーボード / 拡張キー", systemImage: "keyboard")
                    }
                    .disabled(!model.state.acceptsInput)
                    .accessibilityIdentifier("session-show-keyboard")
                    // The deck is not only for a foldable: any device can put
                    // a PC keyboard and a trackpad on the lower half.
                    Button {
                        deckPreference = deckPreference == .always ? .never : .always
                        dismiss()
                    } label: {
                        if deckPreference == .always {
                            Label("手元キーボードを隠す", systemImage: "keyboard.chevron.compact.down")
                        } else {
                            Label("手元キーボード（PC 配列）を表示", systemImage: "keyboard.chevron.compact.down")
                        }
                    }
                    .accessibilityIdentifier("session-toggle-laptop-deck")
                }

                Section("表示") {
                    Picker("表示倍率", selection: Binding(
                        get: { model.runtime.scale },
                        set: { model.setScaleMode($0) }
                    )) {
                        Text("画面に合わせる").tag(InitialScale.fit)
                        Text("100%").tag(InitialScale.oneToOne)
                    }
                    .accessibilityIdentifier("session-scale-picker")
                    // Windows' own Scale, sent with the display layout: what
                    // makes text on a phone-sized desktop readable.
                    Picker("Windows の拡大率", selection: $scalePreference) {
                        Text("自動（端末に合わせる）").tag(RemoteScalePreference.automatic)
                        ForEach(RemoteDisplayScale.choices, id: \.self) { percent in
                            Text("\(percent)%").tag(RemoteScalePreference.fixed(percent))
                        }
                    }
                    .accessibilityIdentifier("session-remote-scale-picker")
                    Picker("手元キーボード表示中の解像度", selection: $foldPolicy) {
                        Text("画面に合わせて変える").tag(FoldResolutionPolicy.resizeToFit)
                        Text("変えずに縮小表示").tag(FoldResolutionPolicy.keepAndScale)
                        Text("表示中の大きさで固定").tag(FoldResolutionPolicy.lockToDeck)
                    }
                    .accessibilityIdentifier("session-fold-resolution-picker")
                    if foldPolicy == .lockToDeck {
                        Text("手元キーボードを隠しても、表示中と同じ解像度のまま大きく表示します。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    // For this session; the connection's own setting is the
                    // one it starts from next time.
                    Picker("解像度", selection: Binding(
                        get: { model.runtime.resolution },
                        set: { model.setResolution($0) }
                    )) {
                        ForEach([ResolutionPolicy.adaptive] + ResolutionPolicy.presets, id: \.self) { policy in
                            Text(Formatting.resolutionLabel(policy)).tag(policy)
                        }
                    }
                    .accessibilityIdentifier("session-resolution-picker")
                    if !model.supportsDynamicResolution, model.state == .connected {
                        Text("このサーバーは接続中の解像度変更に対応していません。接続先の設定で指定すると、次の接続から反映されます。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("画面の端まで使う", isOn: Binding(
                        get: { safeAreaPolicy == .fullScreen },
                        set: { safeAreaPolicy = $0 ? .fullScreen : .avoid }
                    ))
                    .accessibilityIdentifier("session-full-screen-toggle")
                    Text(safeAreaPolicy == .fullScreen
                         ? String(localized: "Dynamic Island や画面の角の下にもデスクトップを表示します。")
                         : String(localized: "Dynamic Island、画面の角、ホームインジケータを避けて表示します。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let size = model.desktopSizeText {
                        LabeledContent(
                            String(localized: "リモート解像度"),
                            value: model.supportsDynamicResolution ? String(localized: "\(size)（可変）") : size
                        )
                    }
                }

                Section("入力") {
                    // Kept across sessions and launches, like the deck's
                    // arrangement: it is about the user's hands, not the host.
                    Picker("画面のタッチ", selection: $touchMode) {
                        Text("タッチした場所を操作").tag(TouchPointerMode.direct)
                        Text("トラックパッドとして使う").tag(TouchPointerMode.trackpad)
                        Text("表示の移動だけ").tag(TouchPointerMode.viewport)
                    }
                    .accessibilityIdentifier("session-touch-mode-picker")
                    Text(touchModeHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    // Kept across sessions and launches, like the touch mode.
                    Toggle("キーボード表示中はポインターに合わせて画面を動かす", isOn: $followsPointerAboveKeyboard)
                        .accessibilityIdentifier("session-follow-pointer-toggle")
                    // Live rather than a profile edit: which way a trackpad
                    // should scroll a remote desktop is settled by trying it.
                    Picker("スクロール方向", selection: Binding(
                        get: { model.runtime.scrollDirection },
                        set: { model.setScrollDirection($0) }
                    )) {
                        Text("標準").tag(ScrollDirection.normal)
                        Text("反転").tag(ScrollDirection.reversed)
                    }
                    .accessibilityIdentifier("session-scroll-picker")
                    // 自動 is the foldable's laptop posture; the other two
                    // let any device use the deck, or a folded one do without.
                    Picker("手元キーボード", selection: $deckPreference) {
                        Text("折りたたみ端末を折り曲げたとき").tag(LaptopDeckPreference.automatic)
                        Text("常に表示").tag(LaptopDeckPreference.always)
                        Text("表示しない").tag(LaptopDeckPreference.never)
                    }
                    .accessibilityIdentifier("session-laptop-deck-picker")
                    if canFloatDeck {
                        Picker("手元キーボードの位置", selection: $deckPlacement) {
                            Text("画面の下").tag(LaptopDeckPlacement.docked)
                            Text("フローティング").tag(LaptopDeckPlacement.floating)
                        }
                        .disabled(deckPreference == .never)
                        .accessibilityIdentifier("session-laptop-deck-placement")
                    }
                    Text(canFloatDeck && deckPlacement == .floating
                         ? String(localized: "上のバーで移動、バー右端のつまみで大きさを変えられます。折りたたみ端末を折り曲げているときはヒンジの下に固定します。")
                         : String(localized: "上端のつまみを上下にドラッグすると高さを変えられます。折りたたみ端末を折り曲げているときはヒンジの位置に固定します。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if canFloatDeck {
                        // Thumbs on a wide screen: the halves at the sides,
                        // the trackpad between them.
                        Toggle("横向きでは左右に分ける", isOn: $splitsDeckInLandscape)
                            .disabled(deckPreference == .never)
                            .accessibilityIdentifier("session-laptop-split-toggle")
                    }
                    if model.deviceHasHinge {
                        // The system decides which way the screen turns; this
                        // only decides whether folding sideways means a deck.
                        Toggle("横向きで折り曲げたときも手元キーボードを出す", isOn: $showsDeckFoldedInLandscape)
                            .disabled(deckPreference != .automatic)
                            .accessibilityIdentifier("session-folded-landscape-toggle")
                        Text(showsDeckFoldedInLandscape
                             ? String(localized: "本のように横向きで少し折ったときも、手元キーボードを画面の下に出します（左右分割の設定に従います）。")
                             : String(localized: "手元キーボードが出るのは、縦向き（ラップトップの形）で折り曲げたときだけです。"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    // Kept across sessions and launches: how the deck is laid
                    // out is a matter of the user's hands, not of the host.
                    Picker("手元側の配置", selection: $deckArrangement) {
                        Text("キーボード / トラックパッド").tag(LaptopDeckArrangement.keyboardAboveTrackpad)
                        Text("トラックパッド / キーボード").tag(LaptopDeckArrangement.trackpadAboveKeyboard)
                        Text("キーボードのみ（画面を触って操作）").tag(LaptopDeckArrangement.keyboardOnly)
                    }
                    .disabled(deckPreference == .never)
                    .accessibilityIdentifier("session-laptop-deck-arrangement")
                    // Only the picture and a few keys change: Command is sent
                    // as Win and Option as Alt either way.
                    Picker("キーボードの見た目", selection: $deckPlatform) {
                        ForEach(LaptopKeyboardPlatform.allCases, id: \.self) { platform in
                            Text(platform.title).tag(platform)
                        }
                    }
                    .disabled(deckPreference == .never)
                    .accessibilityIdentifier("session-laptop-platform")
                    .onChange(of: deckPlatform) { _, platform in
                        // A Mac-only role does not carry over to a PC's keys.
                        if !CapsLockRole.roles(on: platform).contains(capsLockRole) {
                            capsLockRole = .capsLock
                        }
                    }
                    Picker("Caps キー", selection: $capsLockRole) {
                        ForEach(CapsLockRole.roles(on: deckPlatform), id: \.self) { role in
                            Text(role.title(on: deckPlatform)).tag(role)
                        }
                    }
                    .disabled(deckPreference == .never)
                    .accessibilityIdentifier("session-laptop-caps-role")
                    // Without buttons: tap to click, two-finger tap for the
                    // right button, hold then move to drag.
                    Toggle("トラックパッドのクリックボタン", isOn: $showsTrackpadButtons)
                        .disabled(deckPreference == .never || !deckArrangement.hasTrackpad)
                        .accessibilityIdentifier("session-laptop-trackpad-buttons")
                }

                if model.clipboardPolicy != .disabled {
                    clipboardSection
                }

                Section("音声") {
                    Toggle("この端末で再生", isOn: Binding(
                        get: { !model.isAudioMuted },
                        set: { model.setLocallyMuted(!$0) }
                    ))
                    .disabled(!model.configuration.audioPlayback)
                    .accessibilityIdentifier("session-audio-toggle")
                    if !model.configuration.audioPlayback {
                        Text("この接続では音声が無効です（接続設定で変更できます）")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

            }
            .navigationTitle("セッション")
            // The display channel opens after the session is connected, so
            // what the server supports is read again when there is a menu to
            // show it in.
            .task { await model.refresh() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                        .accessibilityIdentifier("session-menu-close")
                }
            }
            .confirmationDialog(
                String(localized: "\(model.displayName) を切断しますか？"),
                isPresented: $confirmingDisconnect,
                titleVisibility: .visible
            ) {
                Button("切断", role: .destructive) {
                    Task { await model.disconnect() }
                }
                .accessibilityIdentifier("session-disconnect-confirm")
            }
        }
        .accessibilityIdentifier("session-menu")
    }
}

extension SessionMenuSheet {
    /// docs/ui-flow.md section 6.2. Both directions start from a tap here;
    /// nothing reads or writes the pasteboard on its own.
    @ViewBuilder
    var clipboardSection: some View {
        Section {
            if model.clipboardPolicy.allowsSend {
                // PasteButton hands over the pasteboard without the system
                // "allow paste" prompt, because the tap itself is the consent.
                PasteButton(payloadType: String.self) { strings in
                    let text = strings.joined(separator: "\n")
                    Task { @MainActor in await model.pasteToRemote(text) }
                }
                .disabled(!model.canSendClipboard)
                .accessibilityIdentifier("clipboard-paste-to-remote")
            }
            if model.clipboardPolicy.allowsReceive {
                Button {
                    Task {
                        if let text = await model.copyRemoteToDevice() {
                            UIPasteboard.general.string = text
                        }
                    }
                } label: {
                    Label("リモートのテキストを端末へコピー", systemImage: "doc.on.clipboard")
                }
                .disabled(!model.canReceiveClipboard)
                .accessibilityIdentifier("clipboard-copy-to-device")
            }
        } header: {
            Text("クリップボード")
        } footer: {
            if model.remoteHasText {
                Text("リモートにテキストがあります")
            } else if model.clipboardPolicy.allowsReceive {
                Text("リモートでテキストをコピーすると、ここから端末へコピーできます")
            }
        }
    }
}

/// State with an icon as well as a colour, so it is not carried by colour
/// alone (docs/ui-flow.md section 10).
struct SessionStateBadge: View {
    let state: SessionState
    let statusText: String

    var body: some View {
        Label(statusText, systemImage: symbol)
            .font(.subheadline)
            .foregroundStyle(color)
    }

    private var symbol: String {
        switch state {
        case .connected: return "checkmark.circle"
        case .connecting, .reconnecting, .disconnecting: return "arrow.triangle.2.circlepath"
        case .awaitingUser: return "person.crop.circle.badge.questionmark"
        case .failed: return "exclamationmark.triangle"
        case .idle, .disconnected: return "minus.circle"
        }
    }

    private var color: Color {
        switch state {
        case .connected: return .green
        case .awaitingUser: return .orange
        case .failed: return .red
        default: return .secondary
        }
    }
}
