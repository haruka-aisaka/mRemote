import Foundation
import SessionCore

enum Formatting {
    static func endpoint(_ endpoint: RemoteEndpoint) -> String {
        endpoint.port == 3389 ? endpoint.host : "\(endpoint.host):\(endpoint.port)"
    }

    static func subtitle(for profile: ConnectionProfile) -> String {
        guard let username = profile.account.username, !username.isEmpty else {
            return endpoint(profile.endpoint)
        }
        if let domain = profile.account.domain, !domain.isEmpty {
            return "\(domain)\\\(username) @ \(endpoint(profile.endpoint))"
        }
        return "\(username) @ \(endpoint(profile.endpoint))"
    }

    static func lastConnected(_ date: Date?) -> String? {
        guard let date else { return nil }
        return date.formatted(.relative(presentation: .named))
    }

    static func stateLabel(_ state: SessionState) -> String {
        switch state {
        case .idle: return "待機中"
        case .connecting: return "接続中"
        case .awaitingUser: return "確認待ち"
        case .connected: return "接続済み"
        case .reconnecting: return "再接続中"
        case .disconnecting: return "切断中"
        case .disconnected: return "切断済み"
        case .failed: return "エラー"
        }
    }

    static func transportLabel(_ security: TransportSecurity) -> String {
        switch security {
        case .nla: return "NLA（TLS）"
        case .tls: return "TLS"
        case .legacyRDP: return "古い RDP セキュリティ"
        }
    }

    static func endReasonLabel(_ reason: RemoteEndReason) -> String {
        switch reason {
        case .anotherConnection:
            return "別の接続が同じユーザーでサインインし、このセッションを引き継ぎました。取り返さないよう、自動では再接続しません。"
        case .disconnectedOnServer:
            return "サーバー側でこのセッションが切断されました。別の端末が同じユーザーで接続した場合もこうなります。取り返さないよう、自動では再接続しません。"
        case .signedOut:
            return "サーバー側でサインアウトされました。"
        case .idleTimeout:
            return "操作がなかったため、サーバーが切断しました。"
        case .signInTimeout:
            return "サインインに時間がかかりすぎたため、サーバーが切断しました。"
        }
    }

    /// What went wrong and what to try, in that order. Technical detail
    /// from the backend stays in English and goes last, for reports.
    static func errorLabel(_ error: RemoteSessionError) -> String {
        switch error {
        case .nameResolutionFailed:
            return "ホスト名が見つかりません。ホスト名のつづりを確認するか、IP アドレスで指定してください。"
        case .networkUnreachable:
            return "ネットワークに到達できません。iPhone/iPad のネットワーク接続と、VPN が必要な接続先ならその接続を確認してください。"
        case .connectionRefused:
            return "接続を拒否されました。ポート番号と、リモート側でリモートデスクトップが有効になっているかを確認してください。"
        case .connectionTimedOut:
            return "応答がないまま時間切れになりました。リモートの電源とネットワーク、ファイアウォールで RDP（通常 3389）が許可されているかを確認してください。"
        case .securityNegotiationFailed:
            return "サーバーと共通のセキュリティ方式がありません。サーバーが TLS/NLA を許可せず古い RDP セキュリティのみを受け付けている可能性があります。必要なら接続設定の「接続方式」で明示的に許可できます。"
        case .tlsHandshakeFailed:
            return "暗号化した通信を始められませんでした。接続設定の「接続方式」がサーバーの設定と合っているか確認してください。"
        case .authenticationFailed:
            return "認証に失敗しました。ユーザー名・パスワード・ドメインを確認してください。Microsoft アカウントはメールアドレスをユーザー名にします。"
        case .accountRestricted:
            return "このアカウントはリモート接続を許可されていません。リモート側で「リモートデスクトップ ユーザー」に加えるか、管理者に確認してください。"
        case .certificateRejected:
            return "サーバー証明書を信頼しなかったため中止しました。接続し直すと、もう一度確認できます。"
        case .userCancelled:
            return "接続を中止しました。"
        case .protocolFailure(let detail):
            return "サーバーとの通信が想定外の形で終わりました。もう一度接続してください。続く場合は、この詳細を添えて報告してください。（\(detail)）"
        case .resourceUnavailable:
            return "メモリなどが足りず接続を始められませんでした。ほかのセッションを閉じてからもう一度試してください。"
        case .internalFailure(let detail):
            return "アプリ内部のエラーです。もう一度接続してください。続く場合は、この詳細を添えて報告してください。（\(detail)）"
        }
    }
}
