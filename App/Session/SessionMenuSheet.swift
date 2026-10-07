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
    @AppStorage(CapsLockRole.storageKey) private var capsLockRole = CapsLockRole.capsLock
    @AppStorage(RemoteScalePreference.storageKey)
    private var scalePreference = RemoteScalePreference.automatic
    @AppStorage(FoldResolutionPolicy.storageKey)
    private var foldPolicy = FoldResolutionPolicy.resizeToFit
    @AppStorage(LaptopDeckArrangement.trackpadButtonsStorageKey) private var showsTrackpadButtons = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(model.displayName).font(.headline)
                        Spacer()
                        SessionStateBadge(state: model.state, statusText: model.statusText)
                    }
                    if model.allowsLegacySecurity {
                        Label(
                            "古い RDP セキュリティを許可した接続先です。暗号は弱く、サーバーの確認もできません。",
                            systemImage: "exclamationmark.shield"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
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
                            Task { await model.retry() }
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
                    Picker("折り曲げたときの解像度", selection: $foldPolicy) {
                        Text("画面に合わせて変える").tag(FoldResolutionPolicy.resizeToFit)
                        Text("変えずに縮小表示").tag(FoldResolutionPolicy.keepAndScale)
                    }
                    .accessibilityIdentifier("session-fold-resolution-picker")
                    if let size = model.desktopSizeText {
                        LabeledContent(
                            "リモート解像度",
                            value: model.supportsDynamicResolution ? "\(size)（可変）" : size
                        )
                    }
                }

                Section("入力") {
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
                    // let any phone use the deck, or a folded one do without.
                    Picker("画面下半分のキーボードとトラックパッド", selection: $model.laptopDeckPreference) {
                        Text("折り曲げたとき").tag(LaptopDeckPreference.automatic)
                        Text("常に表示").tag(LaptopDeckPreference.always)
                        Text("表示しない").tag(LaptopDeckPreference.never)
                    }
                    .accessibilityIdentifier("session-laptop-deck-picker")
                    // Kept across sessions and launches: how the deck is laid
                    // out is a matter of the user's hands, not of the host.
                    Picker("手元側の配置", selection: $deckArrangement) {
                        Text("キーボード / トラックパッド").tag(LaptopDeckArrangement.keyboardAboveTrackpad)
                        Text("トラックパッド / キーボード").tag(LaptopDeckArrangement.trackpadAboveKeyboard)
                        Text("キーボードのみ（画面を触って操作）").tag(LaptopDeckArrangement.keyboardOnly)
                    }
                    .disabled(model.laptopDeckPreference == .never)
                    .accessibilityIdentifier("session-laptop-deck-arrangement")
                    Picker("Caps キー", selection: $capsLockRole) {
                        ForEach(CapsLockRole.windowsRoles, id: \.self) { role in
                            Text(role.title).tag(role)
                        }
                    }
                    .disabled(model.laptopDeckPreference == .never)
                    .accessibilityIdentifier("session-laptop-caps-role")
                    // Without buttons: tap to click, two-finger tap for the
                    // right button, hold then move to drag.
                    Toggle("トラックパッドのクリックボタン", isOn: $showsTrackpadButtons)
                        .disabled(model.laptopDeckPreference == .never || !deckArrangement.hasTrackpad)
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                        .accessibilityIdentifier("session-menu-close")
                }
            }
            .confirmationDialog(
                "\(model.displayName) を切断しますか？",
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
