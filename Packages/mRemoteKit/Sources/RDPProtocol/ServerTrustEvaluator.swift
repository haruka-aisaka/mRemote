import CryptoKit
import Darwin
import Foundation
import Security

/// App-owned copy of a native certificate callback. A bridge must construct
/// each Data with `Data(bytes:count:)` while its native pointer is valid.
public struct PresentedServerCertificate: Equatable, Sendable {
    public let id: UUID
    public let sessionGeneration: UInt64
    public let hostname: String
    public let port: UInt16
    public let certificateChainDER: [Data]

    public init(
        id: UUID = UUID(),
        sessionGeneration: UInt64,
        hostname: String,
        port: UInt16,
        certificateChainDER: [Data]
    ) {
        self.id = id
        self.sessionGeneration = sessionGeneration
        self.hostname = hostname
        self.port = port
        self.certificateChainDER = certificateChainDER.map { source in
            source.withUnsafeBytes { Data($0) }
        }
    }
}

public struct ServerTrustEvaluationOptions: Equatable, Sendable {
    public init(
        additionalAnchorDER: [Data] = [],
        anchorsOnly: Bool = false,
        networkFetchAllowed: Bool = true,
        verificationDate: Date? = nil
    ) {
        self.additionalAnchorDER = additionalAnchorDER
        self.anchorsOnly = anchorsOnly
        self.networkFetchAllowed = networkFetchAllowed
        self.verificationDate = verificationDate
    }

    /// Test-only/private-PKI anchor injection. Production leaves this empty and
    /// therefore evaluates against the platform's authoritative trust store.
    public var additionalAnchorDER: [Data] = []
    public var anchorsOnly = false
    public var networkFetchAllowed = true
    /// Deterministic fixture evaluation only. Production leaves this nil.
    public var verificationDate: Date?
}

public enum ServerTrustDisposition: Equatable, Sendable {
    case trusted
    case userOverridableAnchorFailure
    case hardReject
}

/// Which evaluation decided the outcome. Without this the journal only ever
/// carried the system evaluation's error, which for any self-signed server is
/// the same `errSecNotTrusted` regardless of what actually disqualified the
/// certificate, so a hard reject could not be diagnosed at all.
public enum ServerTrustStage: String, Equatable, Sendable {
    /// The authoritative evaluation against the platform's trust store.
    case systemTrust = "system-trust"
    /// Every presented link and its validity window, anchored at the terminal
    /// certificate the server presented. This is the floor: a certificate that
    /// fails here is broken, not merely outside the platform's trust store.
    case presentedChain = "presented-chain"
    /// The SSL policy's server-purpose requirements, with the name check
    /// dropped. Apple asks for more here than the RDP trust model does.
    case serverPurpose = "server-purpose"
    /// The name check alone, for an endpoint typed as a hostname.
    case hostnameBinding = "hostname-binding"
}

/// Whether the presented certificate was bound to the endpoint the user typed.
///
/// `SecPolicyCreateSSL` can only bind a name that the certificate asserts. A
/// Windows RDP host's self-signed certificate asserts its machine name as a
/// dNSName and never an iPAddress SAN, so an endpoint entered as a bare IPv4/
/// IPv6 literal has no name to match and the SSL policy can only ever fail.
/// For that case the evaluator drops the name check alone and the connection
/// is authenticated by explicit fingerprint review instead. Chain signatures,
/// validity periods, and the serverAuth purpose are still enforced, and a
/// certificate that does carry a matching iPAddress SAN still reaches
/// `.trusted` through the authoritative system evaluation.
public enum ServerTrustHostnameBinding: Equatable, Sendable {
    case verified
    case unverifiableIPLiteral

    public var isVerified: Bool { self == .verified }
}

/// Hash-only evidence for the exact leaf-first DER sequence copied from the
/// native certificate callback. The ordered chain includes the leaf at index
/// zero so evidence can distinguish both a changed leaf and a changed issuer.
public struct ServerCertificateFingerprints: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible {
    public let leafSHA256: String
    public let chainSHA256: [String]

    public init?(certificateChainDER: [Data]) {
        let chainSHA256 = certificateChainDER.map(Self.sha256)
        guard let leafSHA256 = chainSHA256.first else { return nil }
        self.leafSHA256 = leafSHA256
        self.chainSHA256 = chainSHA256
    }

    /// Safe for an exportable diagnostic journal: no DER, names, endpoints,
    /// subjects, issuers, or credentials are retained here.
    public var description: String {
        "leafSHA256=\(leafSHA256) chainSHA256=[\(chainSHA256.joined(separator: ","))]"
    }

    public var debugDescription: String { description }

    private static func sha256(_ der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
    }
}

public struct ServerTrustEvaluation: Equatable, Sendable {
    public let disposition: ServerTrustDisposition
    public let trustResultRawValue: UInt32
    public let errorDomain: String?
    public let errorCode: Int?
    public let certificateFingerprints: ServerCertificateFingerprints
    public let hostnameBinding: ServerTrustHostnameBinding
    /// The evaluation that decided a non-trusted outcome, with its own error
    /// rather than the system evaluation's.
    public var decidingStage: ServerTrustStage?
    public var stageErrorDomain: String?
    public var stageErrorCode: Int?
    /// Repeats dropped from the presented chain before evaluation.
    public var repeatedChainEntries = 0

    public init(
        disposition: ServerTrustDisposition,
        trustResultRawValue: UInt32 = 0,
        errorDomain: String? = nil,
        errorCode: Int? = nil,
        certificateFingerprints: ServerCertificateFingerprints,
        hostnameBinding: ServerTrustHostnameBinding = .verified,
        decidingStage: ServerTrustStage? = nil,
        stageErrorDomain: String? = nil,
        stageErrorCode: Int? = nil,
        repeatedChainEntries: Int = 0
    ) {
        self.disposition = disposition
        self.trustResultRawValue = trustResultRawValue
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.certificateFingerprints = certificateFingerprints
        self.hostnameBinding = hostnameBinding
        self.decidingStage = decidingStage
        self.stageErrorDomain = stageErrorDomain
        self.stageErrorCode = stageErrorCode
        self.repeatedChainEntries = repeatedChainEntries
    }

    public var isTrusted: Bool { disposition == .trusted }
    public var permitsTrustOnce: Bool { disposition == .userOverridableAnchorFailure }

    public var evidenceDescription: String {
        let outcome: String
        switch disposition {
        case .trusted:
            outcome = "system-trusted"
        case .userOverridableAnchorFailure:
            outcome = "trust-once-prompt"
        case .hardReject:
            outcome = "hard-reject"
        }
        let stage = decidingStage.map { " stage=\($0.rawValue)" } ?? ""
        let repeats = repeatedChainEntries == 0
            ? ""
            : " repeated-chain-entries=\(repeatedChainEntries)"
        return "outcome=\(outcome)\(stage)\(repeats) binding=\(bindingEvidence) \(certificateFingerprints); \(summary)"
    }

    private var bindingEvidence: String {
        switch hostnameBinding {
        case .verified: return "hostname-verified"
        case .unverifiableIPLiteral: return "ip-literal-unverified"
        }
    }

    public var summary: String {
        let outcome: String
        switch disposition {
        case .trusted:
            outcome = "trusted"
        case .userOverridableAnchorFailure:
            outcome = decidingStage == .serverPurpose
                ? "outside iOS server-certificate requirements (user review allowed)"
                : "untrusted anchor (user review allowed)"
        case .hardReject:
            outcome = "hard-rejected certificate"
        }
        let binding = hostnameBinding.isVerified
            ? ""
            : "; hostname not verified (IP literal endpoint)"
        let cause: String
        if let decidingStage, let stageErrorDomain, let stageErrorCode {
            cause = "failed at \(decidingStage.rawValue): \(stageErrorDomain)(\(stageErrorCode))"
        } else if let decidingStage {
            cause = "failed at \(decidingStage.rawValue)"
        } else if let errorDomain, let errorCode {
            cause = "\(errorDomain)(\(errorCode))"
        } else {
            cause = "no reported error"
        }
        return "\(outcome); \(cause); SecTrust result=\(trustResultRawValue)\(binding)"
    }
}

public enum ServerTrustEvaluatorError: Error, Equatable, CustomStringConvertible {
    case emptyHostname
    case emptyCertificateChain
    case invalidCertificateDER(index: Int)
    case invalidAnchorDER(index: Int)
    case securityStatus(operation: String, status: OSStatus)
    case missingTrustObject

    public var description: String {
        switch self {
        case .emptyHostname: return "TLS hostname is empty"
        case .emptyCertificateChain: return "certificate chain is empty"
        case let .invalidCertificateDER(index): return "invalid certificate DER at chain index \(index)"
        case let .invalidAnchorDER(index): return "invalid certificate DER at anchor index \(index)"
        case let .securityStatus(operation, status): return "\(operation) failed with OSStatus \(status)"
        case .missingTrustObject: return "Security.framework returned no SecTrust object"
        }
    }
}

public struct ServerTrustEvaluator {
    public init() {}

    /// The authoritative evaluation's trust object: the platform trust store,
    /// or the fixture anchors when a test injects them.
    public func makeTrust(
        for challenge: PresentedServerCertificate,
        options: ServerTrustEvaluationOptions = .init()
    ) throws -> SecTrust {
        try makeTrust(
            certificates: Self.withoutRepeats(try certificates(for: challenge)),
            policy: SecPolicyCreateSSL(true, challenge.hostname as CFString),
            options: options,
            anchorOverride: nil
        )
    }


    /// Ordered from the strictest evaluation to the narrowest, so a rejection
    /// names the requirement that actually failed:
    ///
    /// 1. the platform trust store — anything it accepts is trusted outright;
    /// 2. every presented link, its validity window and the terminal presented
    ///    certificate as the anchor — the floor, below which the certificate is
    ///    broken rather than merely unknown, so failing it is a hard reject;
    /// 3. the SSL policy's server-purpose requirements with the name check
    ///    dropped — Apple asks for more of a server certificate here than the
    ///    RDP trust model does, and identity is established by explicit
    ///    fingerprint review anyway, so failing it warns rather than rejects;
    /// 4. the name check alone, for an endpoint typed as a hostname — a
    ///    mismatch there stays a hard reject with no user override.
    public func evaluate(
        _ challenge: PresentedServerCertificate,
        options: ServerTrustEvaluationOptions = .init()
    ) throws -> ServerTrustEvaluation {
        guard let certificateFingerprints = ServerCertificateFingerprints(
            certificateChainDER: challenge.certificateChainDER
        ) else {
            throw ServerTrustEvaluatorError.emptyCertificateChain
        }
        let presented = try certificates(for: challenge)
        let certificates = Self.withoutRepeats(presented)
        let repeatedChainEntries = presented.count - certificates.count

        func evaluation(
            _ disposition: ServerTrustDisposition,
            _ system: RawTrustEvaluation,
            stage: ServerTrustStage?,
            stageEvaluation: RawTrustEvaluation? = nil,
            binding: ServerTrustHostnameBinding
        ) -> ServerTrustEvaluation {
            ServerTrustEvaluation(
                disposition: disposition,
                trustResultRawValue: system.trustResultRawValue,
                errorDomain: system.errorDomain,
                errorCode: system.errorCode,
                certificateFingerprints: certificateFingerprints,
                hostnameBinding: binding,
                decidingStage: stage,
                stageErrorDomain: (stageEvaluation ?? system).errorDomain,
                stageErrorCode: (stageEvaluation ?? system).errorCode,
                repeatedChainEntries: repeatedChainEntries
            )
        }

        let systemEvaluation = try evaluateTrust(makeTrust(
            certificates: certificates,
            policy: SecPolicyCreateSSL(true, challenge.hostname as CFString),
            options: options,
            anchorOverride: nil
        ))
        if systemEvaluation.isTrusted {
            // The authoritative evaluation always carries the typed hostname,
            // so a name-bearing certificate — including one with a matching
            // iPAddress SAN — is verified here and never reaches the
            // name-relaxed fallback below.
            return evaluation(.trusted, systemEvaluation, stage: nil, binding: .verified)
        }

        let hostnameBinding: ServerTrustHostnameBinding =
            Self.isIPAddressLiteral(challenge.hostname)
                ? .unverifiableIPLiteral
                : .verified

        // Do not infer trust failures from localized error text or unstable
        // error codes. Re-evaluate with the terminal certificate in the
        // presented leaf-first chain explicitly anchored, so Basic X.509
        // validates every presented link and its validity period.
        let presentedAnchors = [certificates[certificates.index(before: certificates.endIndex)]]
        let chainEvaluation = try evaluateTrust(makeTrust(
            certificates: certificates,
            policy: SecPolicyCreateBasicX509(),
            options: options,
            anchorOverride: presentedAnchors
        ))
        guard chainEvaluation.isTrusted else {
            return evaluation(
                .hardReject,
                systemEvaluation,
                stage: .presentedChain,
                stageEvaluation: chainEvaluation,
                binding: hostnameBinding
            )
        }

        // An IP literal endpoint has no name the certificate can assert, so the
        // SSL policy runs without a hostname there. Running it without a name
        // for a typed hostname too separates a name mismatch from every other
        // server-purpose requirement, which the single combined evaluation used
        // to conflate into one undiagnosable rejection.
        let purposeEvaluation = try evaluateTrust(makeTrust(
            certificates: certificates,
            policy: SecPolicyCreateSSL(true, nil),
            options: options,
            anchorOverride: presentedAnchors
        ))
        guard purposeEvaluation.isTrusted else {
            // Every presented link, signature and validity period has already
            // passed, so what remains is a requirement Apple places on a server
            // certificate that the RDP trust model does not — a self-signed host
            // certificate without the serverAuth purpose, for one. Windows' own
            // client warns and continues here, and the connection is
            // authenticated by fingerprint review rather than by the chain, so
            // this warns instead of rejecting. The stage is recorded, and the
            // review UI must state that the certificate is not a valid iOS
            // server certificate.
            return evaluation(
                .userOverridableAnchorFailure,
                systemEvaluation,
                stage: .serverPurpose,
                stageEvaluation: purposeEvaluation,
                binding: hostnameBinding
            )
        }

        if hostnameBinding.isVerified {
            let bindingEvaluation = try evaluateTrust(makeTrust(
                certificates: certificates,
                policy: SecPolicyCreateSSL(true, challenge.hostname as CFString),
                options: options,
                anchorOverride: presentedAnchors
            ))
            guard bindingEvaluation.isTrusted else {
                return evaluation(
                    .hardReject,
                    systemEvaluation,
                    stage: .hostnameBinding,
                    stageEvaluation: bindingEvaluation,
                    binding: hostnameBinding
                )
            }
        }

        // Everything the presented chain can prove holds. The only thing left
        // that the system evaluation objected to is the anchor.
        return evaluation(
            .userOverridableAnchorFailure,
            systemEvaluation,
            stage: .systemTrust,
            binding: hostnameBinding
        )
    }

    /// Some servers present the same certificate more than once —
    /// gnome-remote-desktop sends its self-signed certificate as both the leaf
    /// and the rest of the chain. A repeat makes the trust engine try to build
    /// a path whose issuer is the leaf itself, and it makes the terminal entry
    /// the wrong choice of anchor, so repeats are dropped while the presented
    /// order is kept. Evidence still hashes the chain exactly as presented.
    public static func withoutRepeats(_ certificates: [SecCertificate]) -> [SecCertificate] {
        var seen = Set<Data>()
        return certificates.filter { certificate in
            seen.insert(SecCertificateCopyData(certificate) as Data).inserted
        }
    }

    /// A bare IPv4/IPv6 literal, optionally carrying an IPv6 zone identifier.
    /// Parsed by `inet_pton` so that anything a certificate could plausibly
    /// assert as a dNSName is never mistaken for an address.
    public static func isIPAddressLiteral(_ hostname: String) -> Bool {
        guard !hostname.isEmpty, !hostname.contains("\0") else { return false }
        var address4 = in_addr()
        if hostname.withCString({ inet_pton(AF_INET, $0, &address4) }) == 1 {
            return true
        }
        var address6 = in6_addr()
        let withoutZone = hostname.prefix { $0 != "%" }
        guard !withoutZone.isEmpty else { return false }
        return String(withoutZone).withCString {
            inet_pton(AF_INET6, $0, &address6)
        } == 1
    }

    private struct RawTrustEvaluation {
        let isTrusted: Bool
        let trustResultRawValue: UInt32
        let errorDomain: String?
        let errorCode: Int?
    }

    private func certificates(
        for challenge: PresentedServerCertificate
    ) throws -> [SecCertificate] {
        guard !challenge.hostname.isEmpty, !challenge.hostname.contains("\0") else {
            throw ServerTrustEvaluatorError.emptyHostname
        }
        guard !challenge.certificateChainDER.isEmpty else {
            throw ServerTrustEvaluatorError.emptyCertificateChain
        }
        return try challenge.certificateChainDER.enumerated().map { index, der in
            guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
                throw ServerTrustEvaluatorError.invalidCertificateDER(index: index)
            }
            return certificate
        }
    }

    /// `anchorOverride` nil evaluates against the platform trust store, plus any
    /// fixture anchors the options inject. A non-nil override replaces the
    /// anchors entirely with the certificates the server itself presented.
    private func makeTrust(
        certificates: [SecCertificate],
        policy: SecPolicy,
        options: ServerTrustEvaluationOptions,
        anchorOverride: [SecCertificate]?
    ) throws -> SecTrust {
        var optionalTrust: SecTrust?
        let createStatus = SecTrustCreateWithCertificates(
            certificates as CFArray,
            policy,
            &optionalTrust
        )
        guard createStatus == errSecSuccess else {
            throw ServerTrustEvaluatorError.securityStatus(
                operation: "SecTrustCreateWithCertificates",
                status: createStatus
            )
        }
        guard let trust = optionalTrust else {
            throw ServerTrustEvaluatorError.missingTrustObject
        }
        let anchors: [SecCertificate]
        let anchorsOnly: Bool
        if let anchorOverride {
            anchors = anchorOverride
            anchorsOnly = true
        } else {
            anchors = try options.additionalAnchorDER.enumerated().map { index, der in
                guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
                    throw ServerTrustEvaluatorError.invalidAnchorDER(index: index)
                }
                return certificate
            }
            anchorsOnly = options.anchorsOnly
        }
        if !anchors.isEmpty {
            let anchorStatus = SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            guard anchorStatus == errSecSuccess else {
                throw ServerTrustEvaluatorError.securityStatus(
                    operation: "SecTrustSetAnchorCertificates",
                    status: anchorStatus
                )
            }
            let anchorsOnlyStatus = SecTrustSetAnchorCertificatesOnly(trust, anchorsOnly)
            guard anchorsOnlyStatus == errSecSuccess else {
                throw ServerTrustEvaluatorError.securityStatus(
                    operation: "SecTrustSetAnchorCertificatesOnly",
                    status: anchorsOnlyStatus
                )
            }
        }
        try configureEvaluation(trust, options: options)
        return trust
    }

    private func configureEvaluation(
        _ trust: SecTrust,
        options: ServerTrustEvaluationOptions
    ) throws {
        let networkStatus = SecTrustSetNetworkFetchAllowed(trust, options.networkFetchAllowed)
        guard networkStatus == errSecSuccess else {
            throw ServerTrustEvaluatorError.securityStatus(
                operation: "SecTrustSetNetworkFetchAllowed",
                status: networkStatus
            )
        }
        if let verificationDate = options.verificationDate {
            let dateStatus = SecTrustSetVerifyDate(trust, verificationDate as CFDate)
            guard dateStatus == errSecSuccess else {
                throw ServerTrustEvaluatorError.securityStatus(
                    operation: "SecTrustSetVerifyDate",
                    status: dateStatus
                )
            }
        }
    }

    private func evaluateTrust(_ trust: SecTrust) throws -> RawTrustEvaluation {
        var evaluationError: CFError?
        let isTrusted = SecTrustEvaluateWithError(trust, &evaluationError)
        var trustResult = SecTrustResultType.invalid
        let resultStatus = SecTrustGetTrustResult(trust, &trustResult)
        guard resultStatus == errSecSuccess else {
            throw ServerTrustEvaluatorError.securityStatus(
                operation: "SecTrustGetTrustResult",
                status: resultStatus
            )
        }
        let error = evaluationError as Error? as NSError?
        return RawTrustEvaluation(
            isTrusted: isTrusted,
            trustResultRawValue: trustResult.rawValue,
            errorDomain: error?.domain,
            errorCode: error?.code
        )
    }
}
