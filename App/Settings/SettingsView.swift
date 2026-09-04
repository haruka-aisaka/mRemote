import SwiftUI
import SessionCore

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var settings = GlobalSettings.default

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("キーボードレイアウト", selection: $settings.keyboardLayout) {
                        Text("日本語 106/109").tag(KeyboardLayoutPreference.japanese)
                        Text("US").tag(KeyboardLayoutPreference.us)
                        Text("自動").tag(KeyboardLayoutPreference.automatic)
                    }
                } header: {
                    Text("キーボード")
                } footer: {
                    Text("英数→無変換、かな→変換の変換が保証されるのは日本語レイアウトのみです。接続先ごとに上書きできます。")
                }

                Section("表示") {
                    Picker("初期倍率", selection: $settings.initialScale) {
                        Text("画面に合わせる").tag(InitialScale.fit)
                        Text("100%").tag(InitialScale.oneToOne)
                    }
                }

                Section("入力") {
                    Picker("スクロール方向", selection: $settings.scrollDirection) {
                        Text("通常").tag(ScrollDirection.normal)
                        Text("反転").tag(ScrollDirection.reversed)
                    }
                }

                Section {
                    Toggle("音声を再生", isOn: $settings.audioPlayback)
                    Picker("クリップボード", selection: $settings.clipboardPolicy) {
                        Text("無効").tag(ClipboardPolicy.disabled)
                        Text("双方向").tag(ClipboardPolicy.bidirectional)
                        Text("送信のみ").tag(ClipboardPolicy.sendOnly)
                        Text("受信のみ").tag(ClipboardPolicy.receiveOnly)
                    }
                } header: {
                    Text("チャネル")
                } footer: {
                    Text("双方向は転送を許可する方向の設定です。クリップボードを常時監視するものではなく、転送はコピー/貼り付け操作を起点にします。")
                }

                Section("接続") {
                    Picker("自動再接続", selection: $settings.reconnectPolicy) {
                        Text("しない").tag(ReconnectPolicy.disabled)
                        Text("する").tag(ReconnectPolicy.automatic)
                    }
                }

                Section {
                    NavigationLink("ライセンス") {
                        LicensesView()
                    }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") {
                        let updated = settings
                        Task { await environment.updateGlobalSettings(updated) }
                        dismiss()
                    }
                    .accessibilityIdentifier("settings-done-button")
                }
            }
            .onAppear { settings = environment.globalSettings }
        }
        .accessibilityIdentifier("settings-screen")
    }
}
