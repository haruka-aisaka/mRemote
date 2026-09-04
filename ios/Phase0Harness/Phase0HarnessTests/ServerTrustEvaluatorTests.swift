import XCTest
#if SWIFT_PACKAGE
@testable import Phase0HarnessLogic
#else
@testable import Phase0Harness
#endif

final class ServerTrustEvaluatorTests: XCTestCase {
    private let boundedValidityCertificateDER = Data(base64Encoded: "MIIDTDCCAjSgAwIBAgIUdR9gUIYtmbODo2fQ2ET+d4MhE4EwDQYJKoZIhvcNAQELBQAwFjEUMBIGA1UEAwwLcGhhc2UwLnRlc3QwHhcNMjYwOTA0MDQ0OTMzWhcNMjcwOTA0MDQ0OTMzWjAWMRQwEgYDVQQDDAtwaGFzZTAudGVzdDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAKbJiapTd9kqECfCsdq2TpBJNwt6E7g2a7ZOAc8C3HNdNuYXTysJ2cwdSvfNn8NripdcGcqaBxDgUZ0uv5Zs7urKQP7tGvzrHV2odcjpRgG5OKKckdVycaE2rkJVm0T9IvJ+xHZxPra1qEYdrO11uNs/iMN4UGgQ4sNyWQgbg94hWnIFBVZxgolOqiaxpKZfr5EYMjRxkUwQ3rKI+7X15TAuuk8IwbWED/0LIOViSBwlNF3HNmdSZig6Yzs3/3jSGojXvJPbO5ch106EQUNzN6CuD5innJQkAOG3o2ruu90jn3jWfhJKdKi1hGptAGc2GKoG43KtLIAnbniAB77BjRUCAwEAAaOBkTCBjjAdBgNVHQ4EFgQU/lXdQgZzpLtSl+Tl53tJCsbUqSgwHwYDVR0jBBgwFoAU/lXdQgZzpLtSl+Tl53tJCsbUqSgwFgYDVR0RBA8wDYILcGhhc2UwLnRlc3QwDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMCAqQwEwYDVR0lBAwwCgYIKwYBBQUHAwEwDQYJKoZIhvcNAQELBQADggEBAAUloH65utQpVzjOrOyK0DLB8Ctb/XJQ8mXXp79TB3mYykiqOTSkLgyexJ3yHjOaV/UuvURttdHwHD9q/i7c8o8nEiJGg1htcp2g83Jx9qUg8Wwne0+Dv1QdWmKlBinq7Q6kHGZuUPVMDDirIhn0G40pLE1mzENR+cEWXq188ktDtx6v1AeaYMeNKfhj5BY5/69G/v+E/85IowgRSibh4tfq8TnM7iYc5aHWgQ+I5JK4idmrx6ZRGGyXLYbM/Aabdxi0dTXwNPy+YM1sYjTCtdTFFsfTW7KsLi87vvK0dt4/vNwfZ+7FswKLuAX/XAbUpEXcacflokS5IkxZ1pj8QcM=")!
    private let expiredIntermediateLeafDER = Data(base64Encoded: "MIIDXjCCAkagAwIBAgIUC7+acYVAxNUfZMf0xYfuYnG+xLcwDQYJKoZIhvcNAQELBQAwKzEpMCcGA1UEAwwgUGhhc2UwLVRlc3QtRXhwaXJlZC1JbnRlcm1lZGlhdGUwHhcNMjYwOTA0MDc0NjEwWhcNMjcwOTA0MDc0NjEwWjAWMRQwEgYDVQQDDAtwaGFzZTAudGVzdDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBANDNZ0FPswX+guGTgCleXgS8AtjAkfQ5TrhcLhNfB02JN36wmDcvdOnya66Fy9zW7mEx3ZaNZE7qrj29wa3YIE7QTYndx2scvB0j8J1o5DlCl+oychbyRLnRzG3L7ZfJw4SYHTbowJtm57tBYG/3dgVqqfnOMkFG/vVcSLUxLcHN+u/CWGxWD+ms/gIHzHHm3uaEGPsslp5pjyo/9cvg99oxangBdpNstmpg0ZRzs+L+d3WT3zY3k1kT7eaxL44Oq6tMKOWaStvJLG09RETt72P+vPPqF+oHt+0WtkTn8C8mTANIxjuqKYQpwcBxHSiuOz9l1G9YeLdauAIl8XsKtGMCAwEAAaOBjjCBizAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIFoDATBgNVHSUEDDAKBggrBgEFBQcDATAWBgNVHREEDzANggtwaGFzZTAudGVzdDAdBgNVHQ4EFgQU3ZDNgPjCl8M/8HMe8xRSrx7EbmowHwYDVR0jBBgwFoAUMULW7BtgLGb3vF2Q4vRyuKMJq2UwDQYJKoZIhvcNAQELBQADggEBAGDEyH4thy89FGikSr+1AMfdQmuGJYtOtndiTbxg7gSdP+Ongq5IeufGMTbEZI4ID+vtephTJ/ozgP/8FY+FGX5UZ/9xMSFcjZSsG8/ViMsf+gtzjMAcu/W0PJLjWWobqo3B3snJcrpEcKH/hESJY+CkxW/FGymVgZgT2Ck+PRW/Gc1gQMr4G7dFYxKY3uIH6/5yQyiqb8q2uDDO7PNQzegFPq72eHT4vDwV6emeOolVBaw6ZYJVqnQ6dJQisEFXC/VtiyfEoTf0lXJBGHrB0MVTpU4pTLvLlLzVqqHuULuoDBRt018ApAGotWJRDie79+lquDHud2Wi3bW+UrnIwHQ=")!
    private let expiredIntermediateDER = Data(base64Encoded: "MIIDOjCCAiKgAwIBAgIUN1MWPD4k7XkdyIOBzZ4P7Km2AicwDQYJKoZIhvcNAQELBQAwGzEZMBcGA1UEAwwQUGhhc2UwLVRlc3QtUm9vdDAeFw0yNjA5MDQwNzQ2MTBaFw0yNjA5MDUwNzQ2MTBaMCsxKTAnBgNVBAMMIFBoYXNlMC1UZXN0LUV4cGlyZWQtSW50ZXJtZWRpYXRlMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAnlIogbTVm9rpppyr3QlTqX/VMH3StCwVfSoPn25XiwtpiKiHjPVCECFO4HncQazxsc/nVWyaXfJWLkGIfZ/6ta76vBNkSvJJlJjYasZomb8blpVAhxCaoiK4GgJBJT//Ji6n++f9WPoox++lyYEg7D1BgjE1B3BYopTL6wL9FmU8YahvjNR6Utk0HVt9y7IKy6IGpJMeKP5SUi31xng+4lgi3X6L9JbNEoT25Qe4KdQKyc6KyCnWHYKMsGW8UjUC8B9RKjHgAnQA4NJkoQOV1u4uzbsCN2/Jl9IunavfpIpKa1BfzjjKGUxh69Ax8F7GPeIa2ODcppVAeYrNieAdnwIDAQABo2YwZDASBgNVHRMBAf8ECDAGAQH/AgEAMA4GA1UdDwEB/wQEAwIBBjAdBgNVHQ4EFgQUMULW7BtgLGb3vF2Q4vRyuKMJq2UwHwYDVR0jBBgwFoAUNFBhRFpC51C4T+O+0o/u8XRj8fEwDQYJKoZIhvcNAQELBQADggEBAE8EX/qsrYDJqdAywJTADJTXbc1SDiI7bC7JNaLBOTvq2VJPSkEnopYxf/b3qyO2H+xSEH/JCJvoBp+yFKhK51ldfg6P5Ixblmao+eYMyaWrYVJEF1wHH+9kY4CKEqFJHuDM9sdmQnbLNRuVcmsmdxIe/HFJP/z+e282u6d9dJ6VPZl0Ou1VGE/OUNX3kkm+D235CQB9e7CO7cb6Rvr8Z3h8CTg4vs66i4Ae96JY7mGPnFmtCSTPbX6Qq2/u/60sM2tFcmG/RP3brRJd1BBd2VK5/IZj+Zw8btSqbS/TAO9xt/6j/f8NmQqzZiK6c4RS+5BNexTBXOk8rxvJWrhfRX8=")!
    private let expiredIntermediateRootDER = Data(base64Encoded: "MIIDKjCCAhKgAwIBAgIUefDnzZLTsHfX8I3F0pDmzALwFfMwDQYJKoZIhvcNAQELBQAwGzEZMBcGA1UEAwwQUGhhc2UwLVRlc3QtUm9vdDAeFw0yNjA5MDQwNzQ2MTBaFw0zNjA5MDEwNzQ2MTBaMBsxGTAXBgNVBAMMEFBoYXNlMC1UZXN0LVJvb3QwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC6iSMcpGENOPnSMYJFxgueUHtlF+9Y0eJotHwVoDkhY2KsyLaMnqN0kGWf6f3XBd7F1MosHLCaviiOnqfWpdC3cIIHTNwgPCZ5NIa1i9POKu9jSntNtSdtRbQh425lqn+3hnE2FJDUWizJy97O2oF3PkaS3VKplgGqbsncwXToYHF4ILO0M6ygbpoC/jiL55Ny7xYHkM0qOGSem5rARQ+rrl5hTMum8DsiD0ZMe0Hiv2jMZppcjfU4luPIGSjPLSf5TXj8NgENS/P6UViIgRRP8sJXC0Gn4qtjfP72+8LyiguJIIf5Qd7Gi+ZY4T/TXg003vSvrE8Es0vH8C/PnAqvAgMBAAGjZjBkMB0GA1UdDgQWBBQ0UGFEWkLnULhP477Sj+7xdGPx8TAfBgNVHSMEGDAWgBQ0UGFEWkLnULhP477Sj+7xdGPx8TASBgNVHRMBAf8ECDAGAQH/AgEBMA4GA1UdDwEB/wQEAwIBBjANBgkqhkiG9w0BAQsFAAOCAQEAKrvL7EZ+6R4kU1rWuDAPPxi1zsXPk3ZjsIyb3UWnPQjhtSS5/KISpuEEa7jm3R3rQGD9p/eQACjrtIU64uLRGS5VGoRe5qz3aIq7/K6DKaUt/wbBmWJdDZjT15L6Mh0VaEQSz2PjLf+VOhty/RK33RXv4ogHEKejVhtzpl2un7rjRRjBK+HTSlV7WOXsqkuRL7ORRxKWBqpfgYYiHJTv77J37h9LFZn8/2BCr+F1gbT4ucPhYbddCt31hlUs6YbbAdcWJTECtrlSWSu/oTqE8u2SRJT6XM07EnsqTbOOlfsPYYE1z7/dcWGu9yZ6wg03V7oNzxTJVuJVlrJ5DqxjVw==")!

    func testRejectsEmptyAndInvalidDERBeforeEvaluation() {
        let evaluator = ServerTrustEvaluator()
        XCTAssertThrowsError(try evaluator.makeTrust(for: challenge(chain: []))) { error in
            XCTAssertEqual(error as? ServerTrustEvaluatorError, .emptyCertificateChain)
        }
        XCTAssertThrowsError(try evaluator.makeTrust(for: challenge(chain: [Data([0, 1, 2])]))) { error in
            XCTAssertEqual(error as? ServerTrustEvaluatorError, .invalidCertificateDER(index: 0))
        }
    }

    func testMatchingHostnameIsTrustedWithExplicitTestAnchor() throws {
        let result = try ServerTrustEvaluator().evaluate(
            challenge(hostname: "phase0.test", chain: [boundedValidityCertificateDER]),
            options: optionsWithFixtureAnchor()
        )
        XCTAssertTrue(result.isTrusted, result.summary)
        XCTAssertEqual(result.disposition, .trusted)
        XCTAssertFalse(result.permitsTrustOnce)
    }

    func testHostnameMismatchIsHardRejectedWithoutUserOverride() throws {
        let result = try ServerTrustEvaluator().evaluate(
            challenge(hostname: "wrong.phase0.test", chain: [boundedValidityCertificateDER]),
            options: optionsWithFixtureAnchor()
        )
        XCTAssertFalse(result.isTrusted)
        XCTAssertEqual(result.disposition, .hardReject)
        XCTAssertFalse(result.permitsTrustOnce)
    }

    func testExpiredCertificateIsHardRejectedWithoutUserOverride() throws {
        let result = try ServerTrustEvaluator().evaluate(
            challenge(hostname: "phase0.test", chain: [boundedValidityCertificateDER]),
            options: optionsWithFixtureAnchor(
                verificationDate: "2028-01-01T00:00:00Z"
            )
        )
        XCTAssertFalse(result.isTrusted)
        XCTAssertEqual(result.disposition, .hardReject)
        XCTAssertFalse(result.permitsTrustOnce)
    }

    func testUntrustedSelfSignedAnchorIsTheOnlyUserOverridableClass() throws {
        let result = try ServerTrustEvaluator().evaluate(
            challenge(hostname: "phase0.test", chain: [boundedValidityCertificateDER]),
            options: ServerTrustEvaluationOptions(
                networkFetchAllowed: false,
                verificationDate: ISO8601DateFormatter().date(
                    from: "2026-09-05T00:00:00Z"
                )
            )
        )

        XCTAssertFalse(result.isTrusted)
        XCTAssertEqual(result.disposition, .userOverridableAnchorFailure)
        XCTAssertTrue(result.permitsTrustOnce)
    }

    func testExpiredPresentedIntermediateCannotBeBypassedByTrustOnce() throws {
        let result = try ServerTrustEvaluator().evaluate(
            challenge(
                hostname: "phase0.test",
                chain: [
                    expiredIntermediateLeafDER,
                    expiredIntermediateDER,
                    expiredIntermediateRootDER,
                ]
            ),
            options: ServerTrustEvaluationOptions(
                additionalAnchorDER: [expiredIntermediateRootDER],
                anchorsOnly: true,
                networkFetchAllowed: false,
                verificationDate: ISO8601DateFormatter().date(
                    from: "2026-09-06T00:00:00Z"
                )
            )
        )

        XCTAssertFalse(result.isTrusted)
        XCTAssertEqual(result.disposition, .hardReject, result.summary)
        XCTAssertFalse(result.permitsTrustOnce)
    }

    func testInvalidLeafSignatureCannotBeBypassedByTrustOnce() throws {
        var invalidSignatureLeaf = expiredIntermediateLeafDER
        invalidSignatureLeaf[invalidSignatureLeaf.index(before: invalidSignatureLeaf.endIndex)] ^= 1
        let result = try ServerTrustEvaluator().evaluate(
            challenge(
                hostname: "phase0.test",
                chain: [
                    invalidSignatureLeaf,
                    expiredIntermediateDER,
                    expiredIntermediateRootDER,
                ]
            ),
            options: ServerTrustEvaluationOptions(
                additionalAnchorDER: [expiredIntermediateRootDER],
                anchorsOnly: true,
                networkFetchAllowed: false,
                verificationDate: ISO8601DateFormatter().date(
                    from: "2026-09-04T12:00:00Z"
                )
            )
        )

        XCTAssertFalse(result.isTrusted)
        XCTAssertEqual(result.disposition, .hardReject, result.summary)
        XCTAssertFalse(result.permitsTrustOnce)
    }

    func testValidChainWithOmittedRootUsesTerminalIntermediateForTrustOnce() throws {
        let result = try ServerTrustEvaluator().evaluate(
            challenge(
                hostname: "phase0.test",
                chain: [expiredIntermediateLeafDER, expiredIntermediateDER]
            ),
            options: ServerTrustEvaluationOptions(
                networkFetchAllowed: false,
                verificationDate: ISO8601DateFormatter().date(
                    from: "2026-09-04T12:00:00Z"
                )
            )
        )

        XCTAssertFalse(result.isTrusted)
        XCTAssertEqual(result.disposition, .userOverridableAnchorFailure, result.summary)
        XCTAssertTrue(result.permitsTrustOnce)
    }

    func testChallengeCopiesDERStorage() {
        var source = boundedValidityCertificateDER
        let challenge = challenge(chain: [source])
        source[0] ^= 0xFF
        XCTAssertNotEqual(source, challenge.certificateChainDER[0])
        XCTAssertEqual(challenge.certificateChainDER[0], boundedValidityCertificateDER)
    }

    func testFingerprintEvidenceHashesLeafAndEveryPresentedChainEntry() throws {
        let leaf = Data("server.example|password=hunter2|DER bytes".utf8)
        let issuer = Data("issuer.example|private-chain-material".utf8)
        let fingerprints = try XCTUnwrap(ServerCertificateFingerprints(
            certificateChainDER: [leaf, issuer]
        ))

        XCTAssertEqual(
            fingerprints.leafSHA256,
            "D903AF5359AE6E62AF2D6262FE74E8BDD8B78CD7CDE68EC4C5AB7AAA68143ECF"
        )
        XCTAssertEqual(fingerprints.chainSHA256, [
            "D903AF5359AE6E62AF2D6262FE74E8BDD8B78CD7CDE68EC4C5AB7AAA68143ECF",
            "5EBCEADA47168AA76191DF965C0AD9A05BFFEBF741104FED2FC896C282643C58",
        ])
        XCTAssertFalse(fingerprints.description.contains("server.example"))
        XCTAssertFalse(fingerprints.description.contains("issuer.example"))
        XCTAssertFalse(fingerprints.description.contains("hunter2"))
        XCTAssertFalse(fingerprints.description.contains("DER bytes"))
        XCTAssertEqual(fingerprints.debugDescription, fingerprints.description)
        XCTAssertNil(ServerCertificateFingerprints(certificateChainDER: []))
    }

    func testEveryTrustDispositionHasStableHashOnlyEvidenceOutcome() throws {
        let challenge = challenge(
            hostname: "hostname-must-not-appear.example",
            chain: [boundedValidityCertificateDER]
        )
        let fingerprints = try XCTUnwrap(ServerCertificateFingerprints(
            certificateChainDER: challenge.certificateChainDER
        ))

        for (disposition, expectedOutcome) in [
            (ServerTrustDisposition.trusted, "outcome=system-trusted"),
            (.hardReject, "outcome=hard-reject"),
            (.userOverridableAnchorFailure, "outcome=trust-once-prompt"),
        ] {
            let result = ServerTrustEvaluation(
                disposition: disposition,
                trustResultRawValue: 5,
                errorDomain: "test.error",
                errorCode: -1,
                certificateFingerprints: fingerprints
            )
            XCTAssertTrue(result.evidenceDescription.contains(expectedOutcome))
            XCTAssertTrue(result.evidenceDescription.contains(fingerprints.description))
            XCTAssertFalse(result.evidenceDescription.contains(challenge.hostname))
            XCTAssertFalse(result.evidenceDescription.contains("password"))
            XCTAssertFalse(result.evidenceDescription.contains("MIID"))
        }
    }

    private func challenge(
        hostname: String = "phase0.test",
        chain: [Data]
    ) -> ServerCertificateChallenge {
        ServerCertificateChallenge(
            sessionGeneration: 7,
            hostname: hostname,
            port: 3389,
            certificateChainDER: chain
        )
    }

    private func optionsWithFixtureAnchor(
        verificationDate: String = "2026-09-05T00:00:00Z"
    ) -> ServerTrustEvaluationOptions {
        ServerTrustEvaluationOptions(
            additionalAnchorDER: [boundedValidityCertificateDER],
            anchorsOnly: true,
            networkFetchAllowed: false,
            verificationDate: ISO8601DateFormatter().date(
                from: verificationDate
            )
        )
    }
}

@MainActor
final class CertificateReviewResponseGateTests: XCTestCase {
    func testLifecycleTransitionRejectsPendingResponseExactlyOnce() {
        let gate = CertificateReviewResponseGate()
        let decisions = SendableDecisionRecorder()
        gate.replace { decisions.append($0) }

        XCTAssertTrue(gate.hasPendingResponse)
        gate.rejectForLifecycleTransition()
        gate.rejectForLifecycleTransition()

        XCTAssertFalse(gate.hasPendingResponse)
        XCTAssertEqual(decisions.values, [false])
    }

    func testReplacingReviewRejectsEarlierResponse() {
        let gate = CertificateReviewResponseGate()
        let firstDecision = SendableDecisionRecorder()
        let secondDecision = SendableDecisionRecorder()
        gate.replace { firstDecision.append($0) }
        gate.replace { secondDecision.append($0) }
        gate.resolve(accept: true)

        XCTAssertEqual(firstDecision.values, [false])
        XCTAssertEqual(secondDecision.values, [true])
    }
}

private final class SendableDecisionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []

    func append(_ decision: Bool) {
        lock.lock()
        storage.append(decision)
        lock.unlock()
    }

    var values: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
