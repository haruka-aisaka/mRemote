import SwiftUI
import SessionCore

struct ProfileEditorView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ProfileEditorModel

    var body: some View {
        NavigationStack {
            Form {
                Section("接続先") {
                    TextField("名前", text: $model.displayName)
                        .accessibilityIdentifier("profile-name-field")
                    TextField("ホスト名または IP", text: $model.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("profile-host-field")
                    TextField("ポート", text: $model.portText)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("profile-port-field")
                }

                Section("資格情報") {
                    TextField("ユーザー名", text: $model.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("ドメイン（任意）", text: $model.domain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("パスワード", text: $model.password)
                    Text("パスワードは Keychain にのみ保存され、接続設定のファイルやログには残りません。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("キーボード") {
                    InheritablePicker(
                        title: "レイアウト",
                        selection: $model.keyboardLayout,
                        options: KeyboardLayoutPreference.allCases,
                        label: keyboardLabel
                    )
                    if model.showsJapaneseKeyWarning {
                        Label(
                            "英数→無変換、かな→変換の変換が保証されるのは日本語レイアウトのみです。",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.footnote)
                    }
                }

                Section("セキュリティ") {
                    Picker("接続方式", selection: Binding(
                        get: { model.securityPolicy },
                        set: { model.choose($0) }
                    )) {
                        ForEach(SecurityPolicy.allCases, id: \.self) { policy in
                            Text(securityLabel(policy)).tag(policy)
                        }
                    }
                    .accessibilityIdentifier("profile-security-picker")
                    .alert("レガシー RDP セキュリティを許可しますか？", isPresented: Binding(
                        get: { model.isConfirmingLegacySecurity },
                        set: { if !$0 { model.declineLegacySecurity() } }
                    )) {
                        Button("許可する", role: .destructive) { model.confirmLegacySecurity() }
                        Button("キャンセル", role: .cancel) { model.declineLegacySecurity() }
                    } message: {
                        Text("この接続先だけ、TLS/NLA を使えないサーバーへ古い RDP セキュリティで接続できるようにします。暗号は弱く、サーバーが本物かどうかの確認もできません。信頼できるネットワーク上の、自分が管理するマシンにだけ使ってください。")
                    }
                    if model.showsLegacySecurityWarning {
                        Label(
                            "レガシー RDP セキュリティは暗号強度が低く、資格情報の保護も弱くなります。",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.footnote)
                    }
                }

                Section("チャネル") {
                    InheritablePicker(
                        title: "音声再生",
                        selection: $model.audioPlayback,
                        options: [true, false],
                        label: { $0 ? "有効" : "無効" }
                    )
                    InheritablePicker(
                        title: "クリップボード",
                        selection: $model.clipboardPolicy,
                        options: ClipboardPolicy.allCases,
                        label: clipboardLabel
                    )
                    InheritablePicker(
                        title: "スクロール方向",
                        selection: $model.scrollDirection,
                        options: ScrollDirection.allCases,
                        label: { $0 == .normal ? "通常" : "反転" }
                    )
                }
            }
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .accessibilityIdentifier("profile-cancel-button")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let profile = model.makeProfile() else { return }
                        let password = model.password
                        Task { await environment.save(profile, password: password) }
                        dismiss()
                    }
                    .disabled(!model.isValid)
                    .accessibilityIdentifier("profile-save-button")
                }
            }
        }
    }

    private func keyboardLabel(_ value: KeyboardLayoutPreference) -> String {
        switch value {
        case .japanese: return "日本語 106/109"
        case .us: return "US"
        case .automatic: return "自動"
        }
    }

    private func clipboardLabel(_ value: ClipboardPolicy) -> String {
        switch value {
        case .disabled: return "無効"
        case .bidirectional: return "双方向"
        case .sendOnly: return "送信のみ"
        case .receiveOnly: return "受信のみ"
        }
    }

    private func securityLabel(_ value: SecurityPolicy) -> String {
        switch value {
        case .secureAutomatic: return "自動（安全な方式のみ）"
        case .nlaRequired: return "NLA 必須"
        case .tlsRequired: return "TLS 必須"
        case .legacyExplicit: return "レガシー RDP セキュリティ"
        }
    }
}

/// One control for every setting that can either inherit the global default or
/// override it, so `inherit` looks the same everywhere it appears.
struct InheritablePicker<Value: Hashable & Sendable & Codable>: View {
    let title: String
    @Binding var selection: Inheritable<Value>
    let options: [Value]
    let label: (Value) -> String

    var body: some View {
        Picker(title, selection: Binding(
            get: { Choice(selection) },
            set: { selection = $0.inheritable }
        )) {
            Text("全体設定に従う").tag(Choice<Value>.inherit)
            ForEach(options, id: \.self) { option in
                Text(label(option)).tag(Choice.explicit(option))
            }
        }
    }

    private enum Choice<Wrapped: Hashable & Sendable & Codable>: Hashable {
        case inherit
        case explicit(Wrapped)

        init(_ value: Inheritable<Wrapped>) {
            switch value {
            case .inherit: self = .inherit
            case .explicit(let wrapped): self = .explicit(wrapped)
            }
        }

        var inheritable: Inheritable<Wrapped> {
            switch self {
            case .inherit: return .inherit
            case .explicit(let wrapped): return .explicit(wrapped)
            }
        }
    }
}
