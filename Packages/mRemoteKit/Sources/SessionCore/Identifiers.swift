import Foundation

/// A saved connection target. Distinct from `SessionID` because the same
/// profile can be connected more than once at the same time.
public struct ProfileID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

/// One running connection attempt and its lifetime.
public struct SessionID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

/// Identifies one outstanding question to the user. A challenge may be
/// answered exactly once, so the ID is what makes a late or duplicated answer
/// detectable rather than silently applied to the wrong connection attempt.
public struct ChallengeID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

/// The Keychain account name for a stored password. Profiles keep only this
/// reference: a guessable host name must never be the Keychain account, and
/// the secret itself must never reach the profile store or a log.
public struct CredentialReference: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

/// Increments on every connect attempt within a session. A callback, input
/// event or challenge answer carrying an older generation belongs to a
/// connection that is already gone and must be dropped rather than applied.
public struct SessionGeneration: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(_ rawValue: UInt64 = 1) {
        self.rawValue = rawValue
    }

    public var next: SessionGeneration { SessionGeneration(rawValue &+ 1) }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String { "g\(rawValue)" }
}
