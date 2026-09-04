import SwiftUI
import SessionCore

/// Full screen, with one floating button. The remote desktop will fill this
/// space in Phase 2; until then the placeholder reports the session state so
/// the flow itself can be exercised.
struct SessionWorkspaceView: View {
    @Environment(AppEnvironment.self) private var environment
    @Bindable var model: SessionWorkspaceModel
    @State private var showsMenu = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            desktopPlaceholder
            floatingMenu
        }
        // Naming the container must not hide what is inside it: the status
        // text and the floating menu have to stay individually reachable.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session-workspace")
        .statusBarHidden()
        .alert(item: challengeBinding) { challenge in
            alert(for: challenge)
        }
    }

    private var desktopPlaceholder: some View {
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
            }
            Text("リモート描画は Phase 2 で接続されます。")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private var floatingMenu: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Menu {
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

    private var challengeBinding: Binding<IdentifiedChallenge?> {
        Binding(
            get: { model.pendingChallenge.map(IdentifiedChallenge.init) },
            set: { _ in }
        )
    }

    private func alert(for identified: IdentifiedChallenge) -> Alert {
        switch identified.challenge {
        case .credential(let challenge):
            return Alert(
                title: Text("資格情報が必要です"),
                message: Text("\(challenge.host) に接続するユーザー名とパスワードを入力してください。"),
                primaryButton: .default(Text("キャンセル")) {
                    Task { await model.answer(.cancel) }
                },
                secondaryButton: .default(Text("保存済みを使用")) {
                    Task {
                        await model.answer(.credential(
                            username: challenge.username ?? "",
                            domain: challenge.domain,
                            password: "",
                            save: false
                        ))
                    }
                }
            )
        case .certificate(let challenge):
            guard challenge.disposition.allowsUserApproval else {
                return Alert(
                    title: Text("サーバー証明書を信頼できません"),
                    message: Text(certificateDetail(challenge)),
                    dismissButton: .cancel(Text("接続を中止")) {
                        Task { await model.answer(.cancel) }
                    }
                )
            }
            return Alert(
                title: Text("サーバー証明書の確認"),
                message: Text(certificateDetail(challenge)),
                primaryButton: .cancel(Text("キャンセル")) {
                    Task { await model.answer(.cancel) }
                },
                secondaryButton: .default(Text("今回のみ信頼")) {
                    Task { await model.answer(.trustOnce) }
                }
            )
        }
    }

    private func certificateDetail(_ challenge: CertificateChallenge) -> String {
        var lines = [
            "\(challenge.host):\(challenge.port)",
            "発行先: \(challenge.subject)",
            "発行者: \(challenge.issuer)",
            "SHA-256: \(challenge.leafSHA256)",
        ]
        switch challenge.disposition {
        case .untrustedRoot:
            lines.append("システムが信頼していない CA（自己署名または private CA）です。")
        case .serverPurposeUnmet:
            lines.append("iOS がサーバー証明書に求める要件を満たしていません。fingerprint だけがこのサーバーの識別根拠です。")
        case .hostnameUnverifiable:
            lines.append("接続先が IP アドレスのため、証明書のホスト名は検証されていません。fingerprint だけがこのサーバーの識別根拠です。")
        case .rejected(let reason):
            lines.append("拒否: \(reason)")
        case .fingerprintChanged(let previous):
            lines.append("以前信頼した証明書と異なります。以前: \(previous)")
        }
        return lines.joined(separator: "\n")
    }
}

/// `Alert(item:)` needs an Identifiable; the challenge ID already is the
/// identity, so this only adapts the shape.
struct IdentifiedChallenge: Identifiable {
    let challenge: SessionChallenge

    var id: ChallengeID { challenge.id }
}
