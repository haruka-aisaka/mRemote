import XCTest
import SessionCore
@testable import RDPProtocol

final class CertificateReviewPolicyTests: XCTestCase {
    private let fingerprints = ServerCertificateFingerprints(
        certificateChainDER: [Data([0x01, 0x02, 0x03])]
    )!

    private func evaluation(
        _ disposition: ServerTrustDisposition,
        stage: ServerTrustStage? = nil,
        binding: ServerTrustHostnameBinding = .verified
    ) -> ServerTrustEvaluation {
        ServerTrustEvaluation(
            disposition: disposition,
            certificateFingerprints: fingerprints,
            hostnameBinding: binding,
            decidingStage: stage
        )
    }

    func testSystemTrustIsAcceptedWithoutAskingOrPinning() {
        XCTAssertEqual(
            CertificateReviewPolicy.verdict(evaluation: evaluation(.trusted), pin: .none),
            .accept(reason: .systemTrust)
        )
    }

    func testAStoredApprovalCoversTheSameCertificateAgain() {
        XCTAssertEqual(
            CertificateReviewPolicy.verdict(
                evaluation: evaluation(.userOverridableAnchorFailure, stage: .systemTrust),
                pin: .matches
            ),
            .accept(reason: .storedApproval)
        )
    }

    func testAChangedFingerprintStopsEvenWhenTheNewCertificateIsSystemTrusted() {
        // Being signed by a public CA is not evidence that this is the same
        // machine the user approved, so the pin change is still the question.
        XCTAssertEqual(
            CertificateReviewPolicy.verdict(
                evaluation: evaluation(.trusted),
                pin: .changed(previousLeafSHA256: "AA")
            ),
            .ask(.fingerprintChanged(previousLeafSHA256: "AA"))
        )
    }

    func testAChangedFingerprintIsAskedRatherThanSilentlyReplaced() {
        let verdict = CertificateReviewPolicy.verdict(
            evaluation: evaluation(.userOverridableAnchorFailure, stage: .systemTrust),
            pin: .changed(previousLeafSHA256: "BB")
        )
        XCTAssertEqual(verdict, .ask(.fingerprintChanged(previousLeafSHA256: "BB")))
        guard case .ask(let disposition) = verdict else { return XCTFail("expected a challenge") }
        // docs/data-and-security.md offers a way forward for a reissued
        // certificate, but never the same presentation as a first approval.
        XCTAssertTrue(disposition.allowsUserApproval)
        XCTAssertTrue(disposition.isIdentityChange)
    }

    func testAStoredPinCannotResurrectABrokenCertificate() {
        for pin: CertificatePinState in [.none, .matches, .changed(previousLeafSHA256: "CC")] {
            let verdict = CertificateReviewPolicy.verdict(
                evaluation: evaluation(.hardReject, stage: .presentedChain),
                pin: pin
            )
            guard case .reject = verdict else {
                return XCTFail("hard reject was softened by pin \(pin)")
            }
        }
    }

    func testTheRejectionNamesTheStageThatDecidedIt() {
        XCTAssertEqual(
            CertificateReviewPolicy.verdict(
                evaluation: evaluation(.hardReject, stage: .hostnameBinding),
                pin: .none
            ),
            .reject(reason: "証明書のホスト名が接続先と一致しません")
        )
        XCTAssertEqual(
            CertificateReviewPolicy.verdict(
                evaluation: evaluation(.hardReject, stage: .presentedChain),
                pin: .none
            ),
            .reject(reason: "証明書チェーンの署名または有効期間が不正です")
        )
    }

    func testAnUnknownAnchorAsksWithTheUntrustedRootWording() {
        XCTAssertEqual(
            CertificateReviewPolicy.verdict(
                evaluation: evaluation(.userOverridableAnchorFailure, stage: .systemTrust),
                pin: .none
            ),
            .ask(.untrustedRoot)
        )
    }

    func testAnIPLiteralEndpointAsksAboutTheUncheckedName() {
        XCTAssertEqual(
            CertificateReviewPolicy.verdict(
                evaluation: evaluation(
                    .userOverridableAnchorFailure,
                    stage: .systemTrust,
                    binding: .unverifiableIPLiteral
                ),
                pin: .none
            ),
            .ask(.hostnameUnverifiable)
        )
    }

    func testTheServerPurposeStageOutranksTheHostnameBinding() {
        // Both can be true at once for an IP literal, and the sheet has to
        // say the certificate is not a valid iOS server certificate rather
        // than only that the name was unchecked.
        XCTAssertEqual(
            CertificateReviewPolicy.verdict(
                evaluation: evaluation(
                    .userOverridableAnchorFailure,
                    stage: .serverPurpose,
                    binding: .unverifiableIPLiteral
                ),
                pin: .none
            ),
            .ask(.serverPurposeUnmet)
        )
    }

    func testNoVerdictAcceptsSilentlyWithoutSystemTrustOrAnApproval() {
        // The whole point of the phase 2 exit criterion: nothing reaches
        // `accept` unless the platform trusted it or the user did.
        let unapproved: [ServerTrustEvaluation] = [
            evaluation(.userOverridableAnchorFailure, stage: .systemTrust),
            evaluation(.userOverridableAnchorFailure, stage: .serverPurpose),
            evaluation(.hardReject, stage: .presentedChain),
        ]
        for evaluation in unapproved {
            let verdict = CertificateReviewPolicy.verdict(evaluation: evaluation, pin: .none)
            if case .accept = verdict {
                XCTFail("\(evaluation.disposition) was accepted without review")
            }
        }
    }
}
