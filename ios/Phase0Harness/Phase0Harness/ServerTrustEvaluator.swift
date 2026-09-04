import CryptoKit
import Foundation
import Security

/// App-owned copy of a native certificate callback. A bridge must construct
/// each Data with `Data(bytes:count:)` while its native pointer is valid.
struct ServerCertificateChallenge: Equatable, Sendable {
    let id: UUID
    let sessionGeneration: UInt64
    let hostname: String
    let port: UInt16
    let certificateChainDER: [Data]

    init(
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

enum ServerCertificateDecision: Equatable, Sendable {
    case reject
    case trustOnce(challengeID: UUID, sessionGeneration: UInt64)
    case acceptSystemTrust(challengeID: UUID, sessionGeneration: UInt64)
}

/// Owns at most one generation-bound UI response. Lifecycle transitions use
/// the explicit rejection method so a native connection thread cannot remain
/// blocked behind an alert after the application becomes inactive.
@MainActor
final class CertificateReviewResponseGate {
    private var pendingResponse: (@Sendable (Bool) -> Void)?

    private(set) var hasPendingResponse = false

    func replace(with response: @escaping @Sendable (Bool) -> Void) {
        resolve(accept: false)
        pendingResponse = response
        hasPendingResponse = true
    }

    func resolve(accept: Bool) {
        let response = pendingResponse
        pendingResponse = nil
        hasPendingResponse = false
        response?(accept)
    }

    func rejectForLifecycleTransition() {
        resolve(accept: false)
    }
}

struct ServerTrustEvaluationOptions: Equatable, Sendable {
    /// Test-only/private-PKI anchor injection. Production leaves this empty and
    /// therefore evaluates against the platform's authoritative trust store.
    var additionalAnchorDER: [Data] = []
    var anchorsOnly = false
    var networkFetchAllowed = true
    /// Deterministic fixture evaluation only. Production leaves this nil.
    var verificationDate: Date?
}

enum ServerTrustDisposition: Equatable, Sendable {
    case trusted
    case userOverridableAnchorFailure
    case hardReject
}

/// Hash-only evidence for the exact leaf-first DER sequence copied from the
/// native certificate callback. The ordered chain includes the leaf at index
/// zero so evidence can distinguish both a changed leaf and a changed issuer.
struct ServerCertificateFingerprints: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible {
    let leafSHA256: String
    let chainSHA256: [String]

    init?(certificateChainDER: [Data]) {
        let chainSHA256 = certificateChainDER.map(Self.sha256)
        guard let leafSHA256 = chainSHA256.first else { return nil }
        self.leafSHA256 = leafSHA256
        self.chainSHA256 = chainSHA256
    }

    /// Safe for an exportable diagnostic journal: no DER, names, endpoints,
    /// subjects, issuers, or credentials are retained here.
    var description: String {
        "leafSHA256=\(leafSHA256) chainSHA256=[\(chainSHA256.joined(separator: ","))]"
    }

    var debugDescription: String { description }

    private static func sha256(_ der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
    }
}

struct ServerTrustEvaluation: Equatable, Sendable {
    let disposition: ServerTrustDisposition
    let trustResultRawValue: UInt32
    let errorDomain: String?
    let errorCode: Int?
    let certificateFingerprints: ServerCertificateFingerprints

    var isTrusted: Bool { disposition == .trusted }
    var permitsTrustOnce: Bool { disposition == .userOverridableAnchorFailure }

    var evidenceDescription: String {
        let outcome: String
        switch disposition {
        case .trusted:
            outcome = "system-trusted"
        case .userOverridableAnchorFailure:
            outcome = "trust-once-prompt"
        case .hardReject:
            outcome = "hard-reject"
        }
        return "outcome=\(outcome) \(certificateFingerprints); \(summary)"
    }

    var summary: String {
        let outcome: String
        switch disposition {
        case .trusted:
            outcome = "trusted"
        case .userOverridableAnchorFailure:
            outcome = "untrusted anchor (user review allowed)"
        case .hardReject:
            outcome = "hard-rejected certificate"
        }
        if let errorDomain, let errorCode {
            return "\(outcome) \(errorDomain)(\(errorCode)); SecTrust result=\(trustResultRawValue)"
        }
        return "\(outcome) (SecTrust result=\(trustResultRawValue))"
    }
}

enum ServerTrustEvaluatorError: Error, Equatable, CustomStringConvertible {
    case emptyHostname
    case emptyCertificateChain
    case invalidCertificateDER(index: Int)
    case invalidAnchorDER(index: Int)
    case securityStatus(operation: String, status: OSStatus)
    case missingTrustObject

    var description: String {
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

struct ServerTrustEvaluator {
    func makeTrust(
        for challenge: ServerCertificateChallenge,
        options: ServerTrustEvaluationOptions = .init()
    ) throws -> SecTrust {
        guard !challenge.hostname.isEmpty, !challenge.hostname.contains("\0") else {
            throw ServerTrustEvaluatorError.emptyHostname
        }
        guard !challenge.certificateChainDER.isEmpty else {
            throw ServerTrustEvaluatorError.emptyCertificateChain
        }

        let certificates = try challenge.certificateChainDER.enumerated().map { index, der in
            guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
                throw ServerTrustEvaluatorError.invalidCertificateDER(index: index)
            }
            return certificate
        }
        let policy = SecPolicyCreateSSL(true, challenge.hostname as CFString)
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

        if !options.additionalAnchorDER.isEmpty {
            let anchors = try options.additionalAnchorDER.enumerated().map { index, der in
                guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
                    throw ServerTrustEvaluatorError.invalidAnchorDER(index: index)
                }
                return certificate
            }
            let anchorStatus = SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            guard anchorStatus == errSecSuccess else {
                throw ServerTrustEvaluatorError.securityStatus(
                    operation: "SecTrustSetAnchorCertificates",
                    status: anchorStatus
                )
            }
            let anchorsOnlyStatus = SecTrustSetAnchorCertificatesOnly(trust, options.anchorsOnly)
            guard anchorsOnlyStatus == errSecSuccess else {
                throw ServerTrustEvaluatorError.securityStatus(
                    operation: "SecTrustSetAnchorCertificatesOnly",
                    status: anchorsOnlyStatus
                )
            }
        }
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
        return trust
    }

    func evaluate(
        _ challenge: ServerCertificateChallenge,
        options: ServerTrustEvaluationOptions = .init()
    ) throws -> ServerTrustEvaluation {
        let systemTrust = try makeTrust(for: challenge, options: options)
        guard let certificateFingerprints = ServerCertificateFingerprints(
            certificateChainDER: challenge.certificateChainDER
        ) else {
            throw ServerTrustEvaluatorError.emptyCertificateChain
        }
        let systemEvaluation = try evaluateTrust(systemTrust)
        if systemEvaluation.isTrusted {
            return ServerTrustEvaluation(
                disposition: .trusted,
                trustResultRawValue: systemEvaluation.trustResultRawValue,
                errorDomain: systemEvaluation.errorDomain,
                errorCode: systemEvaluation.errorCode,
                certificateFingerprints: certificateFingerprints
            )
        }

        // Do not infer trust failures from localized error text or unstable
        // error codes. Re-evaluate with the terminal certificate in the
        // presented leaf-first chain explicitly anchored. Basic X.509 then
        // validates every presented link and its validity, while SSL adds
        // hostname and server-purpose checks. Only a chain that passes both
        // can have failed the authoritative evaluation solely because its
        // anchor is outside the system trust store, which is the one Trust
        // Once case.
        let certificates = try certificates(for: challenge)
        let presentedAnchors = [certificates[certificates.index(before: certificates.endIndex)]]
        let basicTrust = try makeTrust(
            certificates: certificates,
            policy: SecPolicyCreateBasicX509(),
            options: options,
            anchorOverride: presentedAnchors
        )
        let basicEvaluation = try evaluateTrust(basicTrust)
        guard basicEvaluation.isTrusted else {
            return ServerTrustEvaluation(
                disposition: .hardReject,
                trustResultRawValue: systemEvaluation.trustResultRawValue,
                errorDomain: systemEvaluation.errorDomain,
                errorCode: systemEvaluation.errorCode,
                certificateFingerprints: certificateFingerprints
            )
        }

        let sslTrust = try makeTrust(
            certificates: certificates,
            policy: SecPolicyCreateSSL(true, challenge.hostname as CFString),
            options: options,
            anchorOverride: presentedAnchors
        )
        let sslEvaluation = try evaluateTrust(sslTrust)
        return ServerTrustEvaluation(
            disposition: sslEvaluation.isTrusted
                ? .userOverridableAnchorFailure
                : .hardReject,
            trustResultRawValue: systemEvaluation.trustResultRawValue,
            errorDomain: systemEvaluation.errorDomain,
            errorCode: systemEvaluation.errorCode,
            certificateFingerprints: certificateFingerprints
        )
    }

    private struct RawTrustEvaluation {
        let isTrusted: Bool
        let trustResultRawValue: UInt32
        let errorDomain: String?
        let errorCode: Int?
    }

    private func certificates(
        for challenge: ServerCertificateChallenge
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

    private func makeTrust(
        certificates: [SecCertificate],
        policy: SecPolicy,
        options: ServerTrustEvaluationOptions,
        anchorOverride: [SecCertificate]
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
        let anchorStatus = SecTrustSetAnchorCertificates(trust, anchorOverride as CFArray)
        guard anchorStatus == errSecSuccess else {
            throw ServerTrustEvaluatorError.securityStatus(
                operation: "SecTrustSetAnchorCertificates",
                status: anchorStatus
            )
        }
        let anchorsOnlyStatus = SecTrustSetAnchorCertificatesOnly(trust, true)
        guard anchorsOnlyStatus == errSecSuccess else {
            throw ServerTrustEvaluatorError.securityStatus(
                operation: "SecTrustSetAnchorCertificatesOnly",
                status: anchorsOnlyStatus
            )
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
