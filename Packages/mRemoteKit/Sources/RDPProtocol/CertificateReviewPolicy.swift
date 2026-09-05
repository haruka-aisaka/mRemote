import Foundation
import SessionCore

/// What the trust store already holds for this endpoint.
///
/// Passed in rather than looked up here so the policy stays a pure function:
/// the Keychain lives in `AppleAdapters`, and a decision this important should
/// be testable without one.
public enum CertificatePinState: Hashable, Sendable {
    case none
    case matches
    /// An approval exists for this endpoint but the certificate is a different
    /// one. Either the server was reissued or something is in the middle, and
    /// nothing but the user can tell those apart.
    case changed(previousLeafSHA256: String)
}

/// The answer the bridge is waiting for.
public enum CertificateVerdict: Hashable, Sendable {
    /// The platform trust store accepted it, or the user's stored approval
    /// covers exactly this certificate. Nothing is asked.
    case accept(reason: AcceptReason)
    /// Raise a challenge. `disposition` says which requirement the user is
    /// being asked about and whether an approval may be offered at all.
    case ask(CertificateDisposition)
    /// Refuse without asking. Used only where an approval would be meaningless
    /// because the certificate is broken rather than unknown.
    case reject(reason: String)

    public enum AcceptReason: Hashable, Sendable {
        case systemTrust
        case storedApproval
    }
}

/// The staged decision from docs/data-and-security.md section 5, with the
/// stored pin folded in.
///
/// The order matters and is not arbitrary:
///
/// 1. A certificate that fails the presented-chain floor is broken - a bad
///    signature, an expired link, a name that does not match a hostname the
///    user typed - and is refused without an approval action. That check comes
///    first so a stored pin can never resurrect a certificate that stopped
///    verifying.
/// 2. A pinned endpoint whose certificate changed always stops, even when the
///    new certificate is system-trusted. Being trusted by a CA is not evidence
///    that this is the same server the user approved.
/// 3. System trust is authoritative for everything else, and needs no pin: a
///    publicly valid certificate does not become more trustworthy for being
///    written to the Keychain.
/// 4. A stored approval covers exactly its own fingerprint at its own
///    endpoint, and only for the classes that were overridable in the first
///    place.
public enum CertificateReviewPolicy {
    public static func verdict(
        evaluation: ServerTrustEvaluation,
        pin: CertificatePinState
    ) -> CertificateVerdict {
        switch evaluation.disposition {
        case .hardReject:
            return .reject(reason: rejectionReason(for: evaluation))

        case .trusted:
            if case .changed(let previous) = pin {
                return .ask(.fingerprintChanged(previousLeafSHA256: previous))
            }
            return .accept(reason: .systemTrust)

        case .userOverridableAnchorFailure:
            switch pin {
            case .changed(let previous):
                return .ask(.fingerprintChanged(previousLeafSHA256: previous))
            case .matches:
                return .accept(reason: .storedApproval)
            case .none:
                return .ask(disposition(for: evaluation))
            }
        }
    }

    /// Which requirement the user is being asked to override. The IP-literal
    /// case is kept separate from an untrusted root because the warning text
    /// has to say that the name was never checked, not merely that the issuer
    /// is unknown.
    static func disposition(for evaluation: ServerTrustEvaluation) -> CertificateDisposition {
        if evaluation.decidingStage == .serverPurpose {
            return .serverPurposeUnmet
        }
        if evaluation.hostnameBinding == .unverifiableIPLiteral {
            return .hostnameUnverifiable
        }
        return .untrustedRoot
    }

    /// Names the stage that decided the rejection rather than repeating the
    /// system evaluation's error, which is `errSecNotTrusted` for every
    /// self-signed certificate and so explains nothing.
    static func rejectionReason(for evaluation: ServerTrustEvaluation) -> String {
        switch evaluation.decidingStage {
        case .presentedChain:
            return "証明書チェーンの署名または有効期間が不正です"
        case .hostnameBinding:
            return "証明書のホスト名が接続先と一致しません"
        case .serverPurpose:
            return "サーバー証明書として使用できません"
        case .systemTrust, .none:
            return "証明書を検証できません"
        }
    }
}
