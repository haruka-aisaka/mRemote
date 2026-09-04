import Foundation

public struct SchemaVersion: RawRepresentable, Hashable, Comparable, Sendable, Codable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: Int) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public static let v1 = SchemaVersion(1)
    /// The version this build writes.
    public static let current = v1
}

/// One step of the upgrade path. Steps are single-version so the chain can be
/// replayed in order from whatever version is on disk.
public protocol SchemaMigration: Sendable {
    var source: SchemaVersion { get }
    var destination: SchemaVersion { get }
    func migrate(_ document: JSONValue) throws -> JSONValue
}

public enum StoreError: Error, Hashable, Sendable {
    /// Written by a newer build. Refused rather than partially read, because
    /// downgrading a store by dropping fields it does not understand loses the
    /// user's settings silently.
    case documentFromFutureVersion(found: SchemaVersion, supported: SchemaVersion)
    case missingSchemaVersion
    case noMigrationPath(from: SchemaVersion, to: SchemaVersion)
    case migrationFailed(from: SchemaVersion, to: SchemaVersion, detail: String)
    case malformedDocument(detail: String)
}

/// Replays migrations until the document reaches the current version.
public struct SchemaMigrator: Sendable {
    private let migrations: [SchemaVersion: any SchemaMigration]
    private let target: SchemaVersion

    public init(migrations: [any SchemaMigration] = [], target: SchemaVersion = .current) {
        self.migrations = Dictionary(
            migrations.map { ($0.source, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.target = target
    }

    public func migrate(_ document: JSONValue) throws -> JSONValue {
        guard let rawVersion = document["schemaVersion"]?.intValue else {
            throw StoreError.missingSchemaVersion
        }
        let version = SchemaVersion(rawVersion)
        guard version <= target else {
            throw StoreError.documentFromFutureVersion(found: version, supported: target)
        }

        var current = version
        var working = document
        while current < target {
            guard let migration = migrations[current] else {
                throw StoreError.noMigrationPath(from: current, to: target)
            }
            do {
                working = try migration.migrate(working)
            } catch {
                throw StoreError.migrationFailed(
                    from: current,
                    to: migration.destination,
                    detail: String(describing: error)
                )
            }
            // Trust the step's declared destination rather than the document's
            // own field, so a migration that forgets to stamp the version
            // cannot spin here forever.
            guard migration.destination > current else {
                throw StoreError.noMigrationPath(from: current, to: target)
            }
            current = migration.destination
            working = working.settingSchemaVersion(current)
        }
        return working
    }
}

extension JSONValue {
    func settingSchemaVersion(_ version: SchemaVersion) -> JSONValue {
        guard var object = objectValue else { return self }
        object["schemaVersion"] = .number(Double(version.rawValue))
        return .object(object)
    }
}
