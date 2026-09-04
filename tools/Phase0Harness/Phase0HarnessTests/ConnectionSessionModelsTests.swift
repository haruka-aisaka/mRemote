import XCTest
#if SWIFT_PACKAGE
@testable import Phase0HarnessLogic
#else
@testable import Phase0Harness
#endif

final class ConnectionSessionModelsTests: XCTestCase {
    func testValidatesAndNormalizesPublicConnectionValues() throws {
        let connection = try form().validated()

        XCTAssertEqual(connection.descriptor, RDPConnectionDescriptor(
            hostname: "rdp.example.test",
            port: 3389,
            domain: "EXAMPLE",
            username: "alice"
        ))
    }

    func testRejectsMissingAndMalformedConnectionValues() {
        XCTAssertThrowsError(try form(hostname: "  ").validated()) { error in
            XCTAssertEqual(error as? RDPConnectionValidationError, .required(.hostname))
        }
        XCTAssertThrowsError(try form(username: "").validated()) { error in
            XCTAssertEqual(error as? RDPConnectionValidationError, .required(.username))
        }
        XCTAssertThrowsError(try form(port: "65536").validated()) { error in
            XCTAssertEqual(error as? RDPConnectionValidationError, .invalidPort)
        }
        XCTAssertThrowsError(try form(password: "").validated()) { error in
            XCTAssertEqual(error as? RDPConnectionValidationError, .required(.password))
        }
        XCTAssertThrowsError(try form(password: "bad\0secret").validated()) { error in
            XCTAssertEqual(error as? RDPConnectionValidationError, .containsNull(.password))
        }
        XCTAssertThrowsError(try form(password: String(repeating: "x", count: 4_097)).validated()) { error in
            XCTAssertEqual(
                error as? RDPConnectionValidationError,
                .tooLong(.password, maximumUTF8Bytes: 4_096)
            )
        }
    }

    func testConnectionIdentifiersAndPasswordAreRedactedFromDescriptionsAndExport() async throws {
        let plaintext = "do-not-export-秘密"
        let hostname = "private-rdp.example.test"
        let domain = "PRIVATE-DOMAIN"
        let username = "private-user"
        let inputForm = form(
            hostname: hostname,
            domain: domain,
            username: username,
            password: plaintext
        )
        for secret in [hostname, domain, username, plaintext] {
            XCTAssertFalse(String(describing: inputForm).contains(secret))
            XCTAssertFalse(String(reflecting: inputForm).contains(secret))
        }

        let connection = try inputForm.validated()
        let redactedEndpoint = RDPDiagnosticRedaction.endpoint(
            port: connection.descriptor.port
        )
        XCTAssertEqual(redactedEndpoint, "endpoint=<redacted>:3389")
        XCTAssertFalse(redactedEndpoint.contains(hostname))
        for secret in [hostname, domain, username, plaintext] {
            XCTAssertFalse(String(describing: connection.descriptor).contains(secret))
            XCTAssertFalse(String(reflecting: connection.descriptor).contains(secret))
            XCTAssertFalse(String(describing: connection).contains(secret))
            XCTAssertFalse(String(reflecting: connection).contains(secret))
        }
        XCTAssertEqual(String(describing: connection.password), "<redacted>")
        XCTAssertEqual(String(reflecting: connection.password), "<redacted>")

        let export = await MainActor.run {
            let journal = EventJournal()
            journal.append(.state, "connecting \(connection)")
            return journal.exportText(environmentNotes: "device-only notes")
        }
        for secret in [hostname, domain, username, plaintext] {
            XCTAssertFalse(export.contains(secret))
        }
        XCTAssertTrue(export.contains("endpoint=<redacted>"))
        XCTAssertTrue(export.contains("account=<redacted>"))
        XCTAssertTrue(export.contains("password=<redacted>"))
    }

    func testSecretCanBeReadForNativeCopyThenCleared() throws {
        let secret = RDPConnectionSecret("pāssword")
        let copied = secret.withNullTerminatedUTF8 { String(cString: $0) }
        XCTAssertEqual(copied, "pāssword")
        XCTAssertEqual(secret.withUTF8Span { _, count in count }, "pāssword".utf8.count)
        XCTAssertFalse(secret.isCleared)

        secret.clear()
        XCTAssertTrue(secret.isCleared)
        XCTAssertEqual(secret.withNullTerminatedUTF8 { String(cString: $0) }, "")
    }

    func testChannelExerciseCountersRejectStaleOrOutOfOrderTelemetry() {
        var counters = Phase0ChannelExerciseCounters(generation: 7)
        XCTAssertTrue(counters.record(Phase0ChannelTelemetry(
            generation: 7,
            sequence: 1,
            channel: .cliprdr,
            transition: .connected
        )))
        XCTAssertTrue(counters.isConnected(.cliprdr))
        XCTAssertFalse(counters.record(Phase0ChannelTelemetry(
            generation: 6,
            sequence: 2,
            channel: .cliprdr,
            transition: .disconnected
        )))
        XCTAssertFalse(counters.record(Phase0ChannelTelemetry(
            generation: 7,
            sequence: 1,
            channel: .cliprdr,
            transition: .disconnected
        )))
        XCTAssertTrue(counters.record(Phase0ChannelTelemetry(
            generation: 7,
            sequence: 2,
            channel: .cliprdr,
            transition: .disconnected
        )))
        XCTAssertFalse(counters.isConnected(.cliprdr))
        XCTAssertEqual(counters.connectedCounts[.cliprdr], 1)
        XCTAssertEqual(counters.disconnectedCounts[.cliprdr], 1)
    }

    func testClipboardTelemetryDescriptionContainsOnlyCountAndHash() {
        let plaintext = "do-not-export-秘密"
        let telemetry = Phase0ClipboardProbeTelemetry(
            generation: 8,
            sequence: 1,
            probeID: 3,
            stage: .dataResponseSent,
            payloadByteCount: plaintext.utf16.count * 2 + 2,
            payloadSHA256: "0123456789ABCDEF",
            statusCode: 0
        )
        let description = telemetry.description
        XCTAssertFalse(description.contains(plaintext))
        XCTAssertTrue(description.contains("bytes="))
        XCTAssertTrue(description.contains("SHA256=0123456789ABCDEF"))

        var counters = Phase0ChannelExerciseCounters(generation: 8)
        XCTAssertTrue(counters.record(telemetry))
        XCTAssertEqual(counters.clipboardStageCounts[.dataResponseSent], 1)
        XCTAssertEqual(counters.clipboardFailureCount, 0)
        XCTAssertFalse(counters.summary.contains(plaintext))
    }

    func testDisplayResizeCountersSeparateSuccessAndFailure() {
        var counters = Phase0ChannelExerciseCounters(generation: 9)
        XCTAssertTrue(counters.record(Phase0DisplayResizeTelemetry(
            generation: 9,
            sequence: 1,
            requestID: 1,
            width: 1920,
            height: 1080,
            statusCode: 0
        )))
        XCTAssertTrue(counters.record(Phase0DisplayResizeTelemetry(
            generation: 9,
            sequence: 2,
            requestID: 2,
            width: 3840,
            height: 2160,
            statusCode: -8
        )))
        XCTAssertEqual(counters.displayResizeSuccessCount, 1)
        XCTAssertEqual(counters.displayResizeFailureCount, 1)
    }

    private func form(
        hostname: String = "  rdp.example.test ",
        port: String = "3389",
        domain: String = " EXAMPLE ",
        username: String = " alice ",
        password: String = "s3cret"
    ) -> RDPConnectionForm {
        RDPConnectionForm(
            hostname: hostname,
            port: port,
            domain: domain,
            username: username,
            password: password
        )
    }
}

@MainActor
final class SwitchingInputSinkTests: XCTestCase {
    func testRoutesToOnlyOneDestination() {
        let journal = EventJournal()
        let recording = RecordingInputSink(journal: journal)
        let session = RecordingInputSink(journal: journal)
        let switching = SwitchingInputSink(recordingSink: recording)
        let input = OutboundInput.hardwareKey(usage: HIDUsage.eisu, transition: .down)

        switching.enqueue(input, generation: 1)
        switching.useSessionSink(session)
        switching.enqueue(input, generation: 2)
        switching.useRecordingSink()
        switching.enqueue(input, generation: 3)

        XCTAssertEqual(recording.events.map(\.1), [1, 3])
        XCTAssertEqual(session.events.map(\.1), [2])
    }

    func testRecordingSinkIsBoundedAndClearRemovesPayloads() {
        let journal = EventJournal()
        let recording = RecordingInputSink(journal: journal, maximumEvents: 2)
        for generation in 1...3 {
            recording.enqueue(.hostASCII("secret-\(generation)"), generation: UInt64(generation))
        }

        XCTAssertEqual(recording.events.map(\.1), [2, 3])
        recording.clear()
        XCTAssertTrue(recording.events.isEmpty)
    }

    func testTextInputDiagnosticsContainOnlyLengths() {
        let plaintext = "do-not-journal-秘密"
        let hostDescription = OutboundInput.hostASCII(plaintext).diagnosticDescription
        let committedDescription = OutboundInput.committedText(plaintext).diagnosticDescription

        for description in [hostDescription, committedDescription] {
            XCTAssertFalse(description.contains(plaintext))
            XCTAssertTrue(description.contains("UTF8=\(plaintext.utf8.count)"))
            XCTAssertFalse(description.contains("SHA256="))
        }
        XCTAssertTrue(committedDescription.contains("UTF16=\(plaintext.utf16.count)"))
        XCTAssertEqual(
            OutboundInput.hostASCII("same-length-a").diagnosticDescription,
            OutboundInput.hostASCII("same-length-b").diagnosticDescription
        )
    }
}
