import Foundation

/// Creates a session for one protocol.
///
/// The registry below is what keeps the app from depending on RDP: the list
/// and the workspace ask for a session by protocol kind, and the RDP
/// implementation is registered at launch. Adding SSH in Phase 8 means
/// registering a second factory, not changing a call site.
public protocol RemoteSessionFactory: Sendable {
    var protocolKind: ProtocolKind { get }
    func makeSession(
        configuration: EffectiveConnectionConfiguration
    ) async throws -> any RemoteSession
}

public struct UnsupportedProtocolError: Error, Hashable, Sendable {
    public let protocolKind: ProtocolKind

    public init(protocolKind: ProtocolKind) {
        self.protocolKind = protocolKind
    }
}

public actor SessionFactoryRegistry {
    private var factories: [ProtocolKind: any RemoteSessionFactory] = [:]

    public init(factories: [any RemoteSessionFactory] = []) {
        for factory in factories {
            self.factories[factory.protocolKind] = factory
        }
    }

    public func register(_ factory: any RemoteSessionFactory) {
        factories[factory.protocolKind] = factory
    }

    public var registeredKinds: Set<ProtocolKind> { Set(factories.keys) }

    public func makeSession(
        kind: ProtocolKind,
        configuration: EffectiveConnectionConfiguration
    ) async throws -> any RemoteSession {
        guard let factory = factories[kind] else {
            throw UnsupportedProtocolError(protocolKind: kind)
        }
        return try await factory.makeSession(configuration: configuration)
    }
}

/// Produces `FakeRemoteSession`, so the app can be exercised end to end before
/// the RDP adapter exists and in UI tests that have no Windows host.
public struct FakeSessionFactory: RemoteSessionFactory {
    public let protocolKind: ProtocolKind
    private let script: FakeRemoteSession.Script

    public init(
        protocolKind: ProtocolKind = .rdp,
        script: FakeRemoteSession.Script = .succeeds
    ) {
        self.protocolKind = protocolKind
        self.script = script
    }

    public func makeSession(
        configuration: EffectiveConnectionConfiguration
    ) async throws -> any RemoteSession {
        FakeRemoteSession(configuration: configuration, script: script)
    }
}
