import SwiftUI
import SessionCore

/// The two questions a connection can stop on. They share a sheet because
/// they share a rule: the connection is blocked until the user answers, and
/// dismissing without answering has to mean cancel rather than "later".
struct SessionChallengeSheet: View {
    let challenge: SessionChallenge
    let defaultUsername: String?
    let defaultDomain: String?
    let onCredential: (String, String?, String, Bool) -> Void
    let onTrust: (Bool) -> Void
    let onCancel: () -> Void

    @State private var username = ""
    @State private var domain = ""
    @State private var password = ""
    @State private var savePassword = true

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("キャンセル", role: .cancel) { onCancel() }
                            .accessibilityIdentifier("challenge-cancel")
                    }
                }
        }
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var content: some View {
        switch challenge {
        case .credential(let credential):
            credentialForm(credential)
        case .certificate(let certificate):
            certificateReview(certificate)
        }
    }

    // MARK: - Credentials

    private func credentialForm(_ challenge: CredentialChallenge) -> some View {
        Form {
            if challenge.storedCredentialWasRejected {
                Section {
                    Label(
                        "保存済みのパスワードが拒否されました。もう一度入力してください。",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }
            Section("\(challenge.host) にサインイン") {
                TextField("ユーザー名", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("challenge-username")
                TextField("ドメイン（任意）", text: $domain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("challenge-domain")
                SecureField("パスワード", text: $password)
                    .textContentType(.password)
                    .accessibilityIdentifier("challenge-password")
                Toggle("このデバイスに保存", isOn: $savePassword)
                    .accessibilityIdentifier("challenge-save-password")
            }
            Section {
                Button("接続") {
                    onCredential(
                        username,
                        domain.isEmpty ? nil : domain,
                        password,
                        savePassword
                    )
                }
                .disabled(username.isEmpty || password.isEmpty)
                .accessibilityIdentifier("challenge-connect")
            } footer: {
                Text("パスワードは Keychain にのみ保存され、接続設定ファイルには書き込まれません。")
            }
        }
        .navigationTitle("資格情報が必要です")
        .onAppear {
            username = challenge.username ?? defaultUsername ?? ""
            domain = challenge.domain ?? defaultDomain ?? ""
        }
    }

    // MARK: - Certificates

    private func certificateReview(_ challenge: CertificateChallenge) -> some View {
        Form {
            Section {
                Label(headline(for: challenge.disposition), systemImage: symbol(for: challenge))
                    .foregroundStyle(challenge.disposition.isIdentityChange ? .red : .orange)
                Text(explanation(for: challenge))
                    .font(.callout)
            }

            Section("証明書") {
                LabeledContent("接続先", value: "\(challenge.host):\(challenge.port)")
                LabeledContent("発行先", value: challenge.subject)
                LabeledContent("発行者", value: challenge.issuer)
                LabeledContent("有効期間", value: validity(for: challenge))
                VStack(alignment: .leading, spacing: 4) {
                    Text("SHA-256 フィンガープリント")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(grouped(challenge.leafSHA256))
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("certificate-fingerprint")
                }
                if case .fingerprintChanged(let previous) = challenge.disposition {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("以前に承認したフィンガープリント")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(grouped(previous))
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            if challenge.disposition.allowsUserApproval {
                Section {
                    Button(challenge.disposition.isIdentityChange
                        ? "変更を承知のうえで今回のみ接続"
                        : "今回のみ信頼") {
                        onTrust(false)
                    }
                    .accessibilityIdentifier("certificate-trust-once")

                    Button(challenge.disposition.isIdentityChange
                        ? "新しい証明書に置き換えて保存"
                        : "この接続先で常に信頼") {
                        onTrust(true)
                    }
                    .accessibilityIdentifier("certificate-trust-always")
                } footer: {
                    Text("承認は \(challenge.host):\(challenge.port) とこのフィンガープリントの組み合わせにだけ適用されます。")
                }
            } else {
                Section {
                    Text("この証明書は承認できません。接続を中止してください。")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("サーバー証明書の確認")
    }

    private func symbol(for challenge: CertificateChallenge) -> String {
        challenge.disposition.isIdentityChange
            ? "exclamationmark.shield.fill"
            : "lock.trianglebadge.exclamationmark"
    }

    private func headline(for disposition: CertificateDisposition) -> String {
        switch disposition {
        case .untrustedRoot:
            return "システムが信頼していない証明書です"
        case .serverPurposeUnmet:
            return "iOS のサーバー証明書要件を満たしていません"
        case .hostnameUnverifiable:
            return "ホスト名を検証できていません"
        case .rejected(let reason):
            return reason
        case .fingerprintChanged:
            return "以前と異なる証明書が提示されました"
        }
    }

    private func explanation(for challenge: CertificateChallenge) -> String {
        switch challenge.disposition {
        case .untrustedRoot:
            return """
            自己署名または独自 CA の証明書です。チェーンと有効期間は確認済みですが、\
            この証明書を保証する第三者はいません。下のフィンガープリントが接続先の\
            サーバーのものであることを、別の手段で確認してください。
            """
        case .serverPurposeUnmet:
            return """
            チェーンと有効期間は確認済みですが、iOS がサーバー証明書に求める要件を\
            満たしていません。Windows のリモートデスクトップが既定で作る証明書は\
            この状態になることがあります。識別の根拠はフィンガープリントだけです。
            """
        case .hostnameUnverifiable:
            return """
            接続先を IP アドレスで指定したため、証明書のホスト名は検証されていません。\
            Windows の自己署名証明書はコンピューター名しか持たないため、IP 指定では\
            照合が成立しません。識別の根拠はフィンガープリントだけです。
            """
        case .rejected(let reason):
            return "\(reason) 承認しても安全にはならないため、接続は中止されます。"
        case .fingerprintChanged:
            return """
            この接続先には以前に承認した証明書があり、今回はそれと異なる証明書が\
            提示されました。サーバーの証明書を更新した場合にも起こりますが、通信が\
            傍受されている場合にも同じことが起こります。心当たりがなければ承認せず、\
            サーバー側で証明書を確認してください。
            """
        }
    }

    private func validity(for challenge: CertificateChallenge) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        guard challenge.notBefore != .distantPast, challenge.notAfter != .distantFuture else {
            return "読み取れません"
        }
        return "\(formatter.string(from: challenge.notBefore)) 〜 \(formatter.string(from: challenge.notAfter))"
    }

    /// A 64 character hex string is unreadable in one run, and reading it is
    /// the entire security value of this sheet.
    private func grouped(_ fingerprint: String) -> String {
        stride(from: 0, to: fingerprint.count, by: 2).map { offset in
            let start = fingerprint.index(fingerprint.startIndex, offsetBy: offset)
            let end = fingerprint.index(start, offsetBy: min(2, fingerprint.count - offset))
            return String(fingerprint[start..<end])
        }.joined(separator: ":")
    }
}
