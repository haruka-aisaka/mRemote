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

    static func errorLabel(_ error: RemoteSessionError) -> String {
        switch error {
        case .nameResolutionFailed: return "ホスト名を解決できません。"
        case .networkUnreachable: return "ネットワークに到達できません。"
        case .connectionRefused: return "接続を拒否されました。ポートとリモートデスクトップの設定を確認してください。"
        case .connectionTimedOut: return "接続がタイムアウトしました。"
        case .tlsHandshakeFailed:
            return "TLS ハンドシェイクに失敗しました。サーバーが TLS/NLA を許可せず古い RDP セキュリティのみを受け付けている場合は、接続設定の「接続方式」で明示的に許可できます。"
        case .authenticationFailed: return "認証に失敗しました。ユーザー名とパスワードを確認してください。"
        case .accountRestricted: return "このアカウントはリモート接続を許可されていません。"
        case .certificateRejected: return "サーバー証明書を信頼しませんでした。"
        case .userCancelled: return "接続を中止しました。"
        case .protocolFailure(let detail): return "プロトコルエラー: \(detail)"
        case .resourceUnavailable: return "接続に必要なリソースを確保できません。"
        case .internalFailure(let detail): return "内部エラー: \(detail)"
        }
    }
}
