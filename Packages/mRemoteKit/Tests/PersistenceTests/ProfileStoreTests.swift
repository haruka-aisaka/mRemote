import XCTest
import SessionCore
@testable import Persistence

final class ProfileDocumentCodecTests: XCTestCase {
    /// One instance per test, with whole-second timestamps: the document is
    /// serialised as ISO 8601, which does not carry fractional seconds, so a
    /// sub-second `Date` would not survive the round trip.
    private let sample: ProfileDocument = {
        let timestamp = Date(timeIntervalSince1970: 1_760_000_000)
        let profile = ConnectionProfile(
            displayName: "desk",
            endpoint: RemoteEndpoint(host: "desk.example", port: 3389),
            account: RemoteAccount(username: "user", domain: "CORP"),
            configuration: .rdp(RDPConfiguration(
                keyboardLayout: .explicit(.japanese),
                securityPolicy: .nlaRequired
            )),
            createdAt: timestamp,
            updatedAt: timestamp
        )
        return ProfileDocument(profiles: [profile], globalSettings: .default)
    }()

    private func sampleDocument() -> ProfileDocument { sample }

    func testRoundTrip() throws {
        let codec = ProfileDocumentCodec()
        let decoded = try codec.decode(try codec.encode(sample))
        XCTAssertEqual(decoded, sample)
        XCTAssertEqual(decoded.schemaVersion, .current)
    }

    func testEncodingIsStable() throws {
        let codec = ProfileDocumentCodec()
        XCTAssertEqual(try codec.encode(sample), try codec.encode(sample))
    }

    func testNoPasswordIsEncodable() throws {
        // The model has nowhere to put a password, so this is a compile-time
        // guarantee; the test states it so a future field cannot quietly add
        // one to the document.
        let encoded = try ProfileDocumentCodec().encode(sampleDocument())
        let text = String(decoding: encoded, as: UTF8.self).lowercased()
        XCTAssertFalse(text.contains("password"))
        XCTAssertFalse(text.contains("secret"))
    }

    func testFutureVersionIsRefused() throws {
        let future = #"{"schemaVersion":99,"profiles":[],"globalSettings":{}}"#
        XCTAssertThrowsError(try ProfileDocumentCodec().decode(Data(future.utf8))) { error in
            guard case StoreError.documentFromFutureVersion(let found, let supported) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(found, SchemaVersion(99))
            XCTAssertEqual(supported, .current)
        }
    }

    func testMissingSchemaVersionIsRefused() {
        let noVersion = #"{"profiles":[]}"#
        XCTAssertThrowsError(try ProfileDocumentCodec().decode(Data(noVersion.utf8))) { error in
            guard case StoreError.missingSchemaVersion = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testMalformedDocumentIsRefused() {
        XCTAssertThrowsError(try ProfileDocumentCodec().decode(Data("not json".utf8))) { error in
            guard case StoreError.malformedDocument = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }
}

/// Exercises the migration chain itself. Only v1 exists today, so the chain is
/// driven with a synthetic step: the point is that the replay machinery works
/// before a real migration has to depend on it.
final class SchemaMigratorTests: XCTestCase {
    private struct RenameStep: SchemaMigration {
        let source = SchemaVersion(1)
        let destination = SchemaVersion(2)

        func migrate(_ document: JSONValue) throws -> JSONValue {
            guard var object = document.objectValue else {
                throw StoreError.malformedDocument(detail: "expected an object")
            }
            object["renamed"] = object.removeValue(forKey: "legacy") ?? .null
            return .object(object)
        }
    }

    private struct FailingStep: SchemaMigration {
        let source = SchemaVersion(1)
        let destination = SchemaVersion(2)

        func migrate(_ document: JSONValue) throws -> JSONValue {
            throw StoreError.malformedDocument(detail: "boom")
        }
    }

    /// A step that claims not to advance the version. Without the guard in the
    /// migrator this would loop forever.
    private struct StallingStep: SchemaMigration {
        let source = SchemaVersion(1)
        let destination = SchemaVersion(1)

        func migrate(_ document: JSONValue) throws -> JSONValue { document }
    }

    private func document(version: Int) -> JSONValue {
        .object([
            "schemaVersion": .number(Double(version)),
            "legacy": .string("value"),
        ])
    }

    func testChainReplaysAndStampsTheNewVersion() throws {
        let migrator = SchemaMigrator(migrations: [RenameStep()], target: SchemaVersion(2))
        let migrated = try migrator.migrate(document(version: 1))
        XCTAssertEqual(migrated["renamed"]?.stringValue, "value")
        XCTAssertNil(migrated["legacy"])
        XCTAssertEqual(migrated["schemaVersion"]?.intValue, 2)
    }

    func testDocumentAlreadyAtTargetIsUntouched() throws {
        let migrator = SchemaMigrator(migrations: [RenameStep()], target: SchemaVersion(1))
        let migrated = try migrator.migrate(document(version: 1))
        XCTAssertEqual(migrated["legacy"]?.stringValue, "value")
    }

    func testMissingStepIsReported() {
        let migrator = SchemaMigrator(migrations: [], target: SchemaVersion(2))
        XCTAssertThrowsError(try migrator.migrate(document(version: 1))) { error in
            guard case StoreError.noMigrationPath(let from, let to) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(from, SchemaVersion(1))
            XCTAssertEqual(to, SchemaVersion(2))
        }
    }

    func testFailingStepReportsWhereItFailed() {
        let migrator = SchemaMigrator(migrations: [FailingStep()], target: SchemaVersion(2))
        XCTAssertThrowsError(try migrator.migrate(document(version: 1))) { error in
            guard case StoreError.migrationFailed(let from, let to, _) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(from, SchemaVersion(1))
            XCTAssertEqual(to, SchemaVersion(2))
        }
    }

    func testStepThatDoesNotAdvanceIsRefusedRatherThanLooping() {
        let migrator = SchemaMigrator(migrations: [StallingStep()], target: SchemaVersion(2))
        XCTAssertThrowsError(try migrator.migrate(document(version: 1))) { error in
            guard case StoreError.noMigrationPath = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }
}
