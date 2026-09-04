import Foundation

/// Something only the user can answer, raised while connecting.
public enum SessionChallenge: Hashable, Sendable {
    case credential(CredentialChallenge)
    case certificate(CertificateChallenge)

    public var id: ChallengeID {
        switch self {
        case .credential(let challenge): return challenge.id
        case .certificate(let challenge): return challenge.id
        }
    }
}

public struct CredentialChallenge: Hashable, Sendable {
    public let id: ChallengeID
    public let generation: SessionGeneration
    public let host: String
    public let username: String?
    public let domain: String?
    /// Set when a stored password was already tried and rejected. The UI uses
    /// it to explain the second prompt, and the connect path uses it to avoid
    /// retrying the same stored secret into an account lockout.
    public let storedCredentialWasRejected: Bool

    public init(
        id: ChallengeID = ChallengeID(),
        generation: SessionGeneration,
        host: String,
        username: String? = nil,
        domain: String? = nil,
        storedCredentialWasRejected: Bool = false
    ) {
        self.id = id
        self.generation = generation
        self.host = host
        self.username = username
        self.domain = domain
        self.storedCredentialWasRejected = storedCredentialWasRejected
    }
}

/// A server certificate the platform did not accept. The DER is already copied
/// out of the native callback by the time this exists: nothing here points at
/// memory the protocol layer owns.
public struct CertificateChallenge: Hashable, Sendable {
    public let id: ChallengeID
    public let generation: SessionGeneration
    public let host: String
    public let port: UInt16
    public let leafSHA256: String
    public let chainSHA256: String
    public let subject: String
    public let issuer: String
    public let notBefore: Date
    public let notAfter: Date
    /// Which requirement the user is being asked to override, and whether an
    /// override may be offered at all.
    public let disposition: CertificateDisposition

    public init(
        id: ChallengeID = ChallengeID(),
        generation: SessionGeneration,
        host: String,
        port: UInt16,
        leafSHA256: String,
        chainSHA256: String,
        subject: String,
        issuer: String,
        notBefore: Date,
        notAfter: Date,
        disposition: CertificateDisposition
    ) {
        self.id = id
        self.generation = generation
        self.host = host
        self.port = port
        self.leafSHA256 = leafSHA256
        self.chainSHA256 = chainSHA256
        self.subject = subject
        self.issuer = issuer
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.disposition = disposition
    }
}

/// Mirrors the staged evaluation in docs/data-and-security.md: a certificate
/// that is broken is refused outright, while one that is merely unknown, or
/// that cannot bind a name because the endpoint is an IP literal, may be
/// approved with the fingerprint as the only identity.
public enum CertificateDisposition: Hashable, Sendable {
    /// Private CA or self-signed, but otherwise sound.
    case untrustedRoot
    /// Sound chain that does not meet Apple's server-certificate requirements.
    case serverPurposeUnmet
    /// The endpoint is an IP literal, so the name was never checked.
    case hostnameUnverifiable
    /// Expired, mismatched hostname, or a broken chain. No override offered.
    case rejected(reason: String)
    /// A previously pinned fingerprint changed. Never approve this the way a
    /// first-time self-signed certificate is approved.
    case fingerprintChanged(previousLeafSHA256: String)

    public var allowsUserApproval: Bool {
        switch self {
        case .untrustedRoot, .serverPurposeUnmet, .hostnameUnverifiable:
            return true
        case .rejected, .fingerprintChanged:
            return false
        }
    }
}

public enum ChallengeResponse: Hashable, Sendable {
    case credential(username: String, domain: String?, password: String, save: Bool)
    case trustOnce
    case trustPersistently
    case cancel
}

public enum DisconnectReason: Hashable, Sendable {
    case userRequested
    case profileDeleted
    case sceneTerminating
    case replacedByReconnect
    case failed(RemoteSessionError)
}

/// Stable categories the UI can explain. The protocol layer maps its own error
/// codes into these so that no FreeRDP type reaches a feature module.
public enum RemoteSessionError: Hashable, Sendable, Error {
    case nameResolutionFailed
    case networkUnreachable
    case connectionRefused
    case connectionTimedOut
    case tlsHandshakeFailed
    case authenticationFailed
    case accountRestricted
    case certificateRejected
    case userCancelled
    case protocolFailure(detail: String)
    case resourceUnavailable
    case internalFailure(detail: String)

    /// Whether an automatic retry could plausibly succeed without the user
    /// changing anything. Retrying an authentication failure risks locking the
    /// account out, so it is deliberately excluded.
    public var isRetriable: Bool {
        switch self {
        case .networkUnreachable, .connectionTimedOut, .protocolFailure:
            return true
        case .nameResolutionFailed, .connectionRefused, .tlsHandshakeFailed,
             .authenticationFailed, .accountRestricted, .certificateRejected,
             .userCancelled, .resourceUnavailable, .internalFailure:
            return false
        }
    }
}
