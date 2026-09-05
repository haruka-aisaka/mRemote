import XCTest
@testable import RDPProtocol

/// The fixtures are the Phase 0 harness's, so the parser is exercised against
/// the same certificates the trust evaluator already runs on.
final class CertificateSummaryTests: XCTestCase {
    /// CN=phase0.test, self-signed, valid 2026-09-04 to 2027-09-04.
    private let selfSignedDER = Data(base64Encoded: "MIIDTDCCAjSgAwIBAgIUdR9gUIYtmbODo2fQ2ET+d4MhE4EwDQYJKoZIhvcNAQELBQAwFjEUMBIGA1UEAwwLcGhhc2UwLnRlc3QwHhcNMjYwOTA0MDQ0OTMzWhcNMjcwOTA0MDQ0OTMzWjAWMRQwEgYDVQQDDAtwaGFzZTAudGVzdDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAKbJiapTd9kqECfCsdq2TpBJNwt6E7g2a7ZOAc8C3HNdNuYXTysJ2cwdSvfNn8NripdcGcqaBxDgUZ0uv5Zs7urKQP7tGvzrHV2odcjpRgG5OKKckdVycaE2rkJVm0T9IvJ+xHZxPra1qEYdrO11uNs/iMN4UGgQ4sNyWQgbg94hWnIFBVZxgolOqiaxpKZfr5EYMjRxkUwQ3rKI+7X15TAuuk8IwbWED/0LIOViSBwlNF3HNmdSZig6Yzs3/3jSGojXvJPbO5ch106EQUNzN6CuD5innJQkAOG3o2ruu90jn3jWfhJKdKi1hGptAGc2GKoG43KtLIAnbniAB77BjRUCAwEAAaOBkTCBjjAdBgNVHQ4EFgQU/lXdQgZzpLtSl+Tl53tJCsbUqSgwHwYDVR0jBBgwFoAU/lXdQgZzpLtSl+Tl53tJCsbUqSgwFgYDVR0RBA8wDYILcGhhc2UwLnRlc3QwDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMCAqQwEwYDVR0lBAwwCgYIKwYBBQUHAwEwDQYJKoZIhvcNAQELBQADggEBAAUloH65utQpVzjOrOyK0DLB8Ctb/XJQ8mXXp79TB3mYykiqOTSkLgyexJ3yHjOaV/UuvURttdHwHD9q/i7c8o8nEiJGg1htcp2g83Jx9qUg8Wwne0+Dv1QdWmKlBinq7Q6kHGZuUPVMDDirIhn0G40pLE1mzENR+cEWXq188ktDtx6v1AeaYMeNKfhj5BY5/69G/v+E/85IowgRSibh4tfq8TnM7iYc5aHWgQ+I5JK4idmrx6ZRGGyXLYbM/Aabdxi0dTXwNPy+YM1sYjTCtdTFFsfTW7KsLi87vvK0dt4/vNwfZ+7FswKLuAX/XAbUpEXcacflokS5IkxZ1pj8QcM=")!

    /// CN=phase0.test issued by CN=Phase0-Test-Expired-Intermediate: the
    /// subject and issuer differ, so a parser that returns the same name twice
    /// fails here.
    private let issuedLeafDER = Data(base64Encoded: "MIIDXjCCAkagAwIBAgIUC7+acYVAxNUfZMf0xYfuYnG+xLcwDQYJKoZIhvcNAQELBQAwKzEpMCcGA1UEAwwgUGhhc2UwLVRlc3QtRXhwaXJlZC1JbnRlcm1lZGlhdGUwHhcNMjYwOTA0MDc0NjEwWhcNMjcwOTA0MDc0NjEwWjAWMRQwEgYDVQQDDAtwaGFzZTAudGVzdDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBANDNZ0FPswX+guGTgCleXgS8AtjAkfQ5TrhcLhNfB02JN36wmDcvdOnya66Fy9zW7mEx3ZaNZE7qrj29wa3YIE7QTYndx2scvB0j8J1o5DlCl+oychbyRLnRzG3L7ZfJw4SYHTbowJtm57tBYG/3dgVqqfnOMkFG/vVcSLUxLcHN+u/CWGxWD+ms/gIHzHHm3uaEGPsslp5pjyo/9cvg99oxangBdpNstmpg0ZRzs+L+d3WT3zY3k1kT7eaxL44Oq6tMKOWaStvJLG09RETt72P+vPPqF+oHt+0WtkTn8C8mTANIxjuqKYQpwcBxHSiuOz9l1G9YeLdauAIl8XsKtGMCAwEAAaOBjjCBizAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIFoDATBgNVHSUEDDAKBggrBgEFBQcDATAWBgNVHREEDzANggtwaGFzZTAudGVzdDAdBgNVHQ4EFgQU3ZDNgPjCl8M/8HMe8xRSrx7EbmowHwYDVR0jBBgwFoAUMULW7BtgLGb3vF2Q4vRyuKMJq2UwDQYJKoZIhvcNAQELBQADggEBAGDEyH4thy89FGikSr+1AMfdQmuGJYtOtndiTbxg7gSdP+Ongq5IeufGMTbEZI4ID+vtephTJ/ozgP/8FY+FGX5UZ/9xMSFcjZSsG8/ViMsf+gtzjMAcu/W0PJLjWWobqo3B3snJcrpEcKH/hESJY+CkxW/FGymVgZgT2Ck+PRW/Gc1gQMr4G7dFYxKY3uIH6/5yQyiqb8q2uDDO7PNQzegFPq72eHT4vDwV6emeOolVBaw6ZYJVqnQ6dJQisEFXC/VtiyfEoTf0lXJBGHrB0MVTpU4pTLvLlLzVqqHuULuoDBRt018ApAGotWJRDie79+lquDHud2Wi3bW+UrnIwHQ=")!

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    func testReadsSubjectIssuerAndValidityFromASelfSignedCertificate() throws {
        let summary = try XCTUnwrap(
            CertificateSummaryParser.summary(fromLeafDER: selfSignedDER)
        )
        XCTAssertEqual(summary.subject, "CN=phase0.test")
        XCTAssertEqual(summary.issuer, "CN=phase0.test")
        XCTAssertEqual(summary.notBefore, date("2026-09-04T04:49:33Z"))
        XCTAssertEqual(summary.notAfter, date("2027-09-04T04:49:33Z"))
    }

    func testSubjectAndIssuerAreReadFromTheirOwnFields() throws {
        let summary = try XCTUnwrap(
            CertificateSummaryParser.summary(fromLeafDER: issuedLeafDER)
        )
        XCTAssertEqual(summary.subject, "CN=phase0.test")
        XCTAssertEqual(summary.issuer, "CN=Phase0-Test-Expired-Intermediate")
        XCTAssertLessThan(summary.notBefore, summary.notAfter)
    }

    func testTruncatedCertificatesReturnNilRatherThanTrapping() {
        for length in stride(from: 0, to: selfSignedDER.count, by: 7) {
            _ = CertificateSummaryParser.summary(fromLeafDER: selfSignedDER.prefix(length))
        }
        XCTAssertNil(CertificateSummaryParser.summary(fromLeafDER: Data()))
        XCTAssertNil(CertificateSummaryParser.summary(fromLeafDER: Data([0x30, 0x82, 0xFF, 0xFF])))
    }

    func testCorruptedBytesReturnNilRatherThanTrapping() {
        // Every single-byte corruption of the header region has to be handled;
        // these bytes came off a socket.
        var random = SystemRandomNumberGenerator()
        for _ in 0..<400 {
            var mutated = selfSignedDER
            let index = Int.random(in: 0..<min(mutated.count, 400), using: &random)
            mutated[mutated.startIndex + index] ^= UInt8.random(in: 1...255, using: &random)
            _ = CertificateSummaryParser.summary(fromLeafDER: mutated)
        }
    }

    func testALengthThatClaimsMoreThanThereIsIsRefused() {
        // SEQUENCE with a four-byte length of 0x7FFFFFFF over three bytes of
        // content.
        let claim = Data([0x30, 0x84, 0x7F, 0xFF, 0xFF, 0xFF, 0x01, 0x02, 0x03])
        XCTAssertNil(CertificateSummaryParser.summary(fromLeafDER: claim))
    }

    func testTheIndefiniteLengthFormIsRefused() {
        XCTAssertNil(CertificateSummaryParser.summary(fromLeafDER: Data([0x30, 0x80, 0x00, 0x00])))
    }
}
