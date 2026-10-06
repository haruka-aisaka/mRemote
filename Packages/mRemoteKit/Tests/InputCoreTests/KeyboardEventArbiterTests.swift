import XCTest
import SessionCore
@testable import InputCore

final class KeyboardEventArbiterTests: XCTestCase {
    private let a: UInt16 = 0x04
    private let leftControl: UInt16 = 0xE0
    private let kana: UInt16 = 0x90
    private let eisu: UInt16 = 0x91

    private func openArbiter(
        policy: KeyboardSourcePolicy = .baseline
    ) -> KeyboardEventArbiter {
        var arbiter = KeyboardEventArbiter(policy: policy)
        _ = arbiter.setGate(open: true)
        return arbiter
    }

    // MARK: - Sources

    func testOnlyTheBoundSourceReachesTheHost() {
        // KEY-04: the same physical press observed by both sources is sent once.
        var arbiter = openArbiter()
        XCTAssertEqual(
            arbiter.receive(usage: eisu, transition: .down, from: .uiKit).events,
            [KeyboardInput(usage: eisu, transition: .down)]
        )
        XCTAssertEqual(arbiter.receive(usage: eisu, transition: .down, from: .gameController).events, [])
        XCTAssertEqual(arbiter.receive(usage: eisu, transition: .up, from: .gameController).events, [])
        XCTAssertEqual(
            arbiter.receive(usage: eisu, transition: .up, from: .uiKit).events,
            [KeyboardInput(usage: eisu, transition: .up)]
        )
        XCTAssertEqual(arbiter.diagnostics.count(.forwarded), 2)
        XCTAssertEqual(arbiter.diagnostics.count(.otherSource), 2)
    }

    func testAGameControllerBoundUsageIgnoresUIKit() {
        var arbiter = openArbiter(policy: KeyboardSourcePolicy(overrides: [eisu: .gameController]))
        XCTAssertEqual(arbiter.receive(usage: eisu, transition: .down, from: .uiKit).events, [])
        XCTAssertEqual(
            arbiter.receive(usage: eisu, transition: .down, from: .gameController).events,
            [KeyboardInput(usage: eisu, transition: .down)]
        )
    }

    func testAnUnsupportedUsageIsNeverSent() {
        var arbiter = openArbiter(policy: KeyboardSourcePolicy(overrides: [kana: .unsupported]))
        XCTAssertEqual(arbiter.receive(usage: kana, transition: .down, from: .uiKit).events, [])
        XCTAssertEqual(arbiter.receive(usage: kana, transition: .down, from: .gameController).events, [])
    }

    // MARK: - Gate

    func testAClosedGateDeliversNothingAndClosingReleases() {
        var arbiter = KeyboardEventArbiter()
        XCTAssertEqual(arbiter.receive(usage: a, transition: .down, from: .uiKit).events, [])
        XCTAssertEqual(arbiter.diagnostics.count(.gated), 1)

        _ = arbiter.setGate(open: true)
        _ = arbiter.receive(usage: leftControl, transition: .down, from: .uiKit)
        XCTAssertEqual(
            arbiter.setGate(open: false).events,
            [KeyboardInput(usage: leftControl, transition: .up)]
        )
        XCTAssertEqual(arbiter.diagnostics.count(.gateClosed), 1)
        XCTAssertNil(arbiter.repeatDown())
    }

    // MARK: - Quarantine

    func testAKeyHeldAcrossAReleaseNeverReachesTheHostAgain() {
        // Control held while a menu opens: the host gets its up at the
        // release, and the eventual physical up must not become a second one.
        var arbiter = openArbiter()
        _ = arbiter.receive(usage: leftControl, transition: .down, from: .uiKit)
        XCTAssertEqual(
            arbiter.releaseAll(reason: .focusLost).events,
            [KeyboardInput(usage: leftControl, transition: .up)]
        )
        XCTAssertEqual(arbiter.quarantined, [leftControl])
        XCTAssertEqual(arbiter.receive(usage: leftControl, transition: .up, from: .uiKit).events, [])
        XCTAssertTrue(arbiter.quarantined.isEmpty)
        XCTAssertEqual(arbiter.diagnostics.count(.quarantined), 1)
        XCTAssertEqual(
            arbiter.receive(usage: leftControl, transition: .down, from: .uiKit).events,
            [KeyboardInput(usage: leftControl, transition: .down)]
        )
    }

    func testAMissedUpCostsExactlyOneCycle() {
        // The up went to another app. Without a snapshot the next full cycle
        // re-establishes neutral and is swallowed rather than guessed at.
        var arbiter = openArbiter()
        _ = arbiter.receive(usage: a, transition: .down, from: .uiKit)
        _ = arbiter.releaseAll(reason: .focusLost)
        XCTAssertEqual(arbiter.receive(usage: a, transition: .down, from: .uiKit).events, [])
        XCTAssertEqual(arbiter.receive(usage: a, transition: .up, from: .uiKit).events, [])
        XCTAssertEqual(
            arbiter.receive(usage: a, transition: .down, from: .uiKit).events,
            [KeyboardInput(usage: a, transition: .down)]
        )
    }

    func testTheOtherSourceCanLiftAQuarantine() {
        // GameController keeps reporting while the surface is not first
        // responder, which is what lets a quarantine clear in the background.
        var arbiter = openArbiter()
        _ = arbiter.receive(usage: a, transition: .down, from: .uiKit)
        _ = arbiter.receive(usage: a, transition: .down, from: .gameController)
        _ = arbiter.releaseAll(reason: .focusLost)
        _ = arbiter.receive(usage: a, transition: .up, from: .gameController)
        // UIKit still believes it is down: the UIKit up has not arrived.
        XCTAssertEqual(arbiter.quarantined, [a])
        _ = arbiter.receive(usage: a, transition: .up, from: .uiKit)
        XCTAssertTrue(arbiter.quarantined.isEmpty)
    }

    func testASnapshotLiftsStaleQuarantine() {
        var arbiter = openArbiter()
        _ = arbiter.receive(usage: leftControl, transition: .down, from: .uiKit)
        _ = arbiter.receive(usage: a, transition: .down, from: .uiKit)
        _ = arbiter.releaseAll(reason: .focusLost)
        arbiter.reconcile(physicallyHeld: [a])
        XCTAssertEqual(arbiter.quarantined, [a])
        XCTAssertEqual(arbiter.physicallyHeld, [a])
        XCTAssertEqual(
            arbiter.receive(usage: leftControl, transition: .down, from: .uiKit).events,
            [KeyboardInput(usage: leftControl, transition: .down)]
        )
    }

    func testDisconnectingASourceForgetsWhatItHeld() {
        var arbiter = openArbiter(policy: KeyboardSourcePolicy(overrides: [eisu: .gameController]))
        _ = arbiter.receive(usage: eisu, transition: .down, from: .gameController)
        XCTAssertEqual(
            arbiter.sourceDisconnected(.gameController).events,
            [KeyboardInput(usage: eisu, transition: .up)]
        )
        XCTAssertTrue(arbiter.quarantined.isEmpty)
        XCTAssertEqual(arbiter.diagnostics.count(.keyboardDisconnected), 1)
    }

    func testAPolicyChangeReleasesFirst() {
        var arbiter = openArbiter()
        _ = arbiter.receive(usage: eisu, transition: .down, from: .uiKit)
        XCTAssertEqual(
            arbiter.setPolicy(KeyboardSourcePolicy(overrides: [eisu: .gameController])).events,
            [KeyboardInput(usage: eisu, transition: .up)]
        )
        // The press that began under UIKit cannot end under GameController.
        XCTAssertEqual(arbiter.receive(usage: eisu, transition: .up, from: .gameController).events, [])
    }

    // MARK: - Diagnostics

    func testTheTraceRecordsOnlyNonCharacterKeysAndOnlyWhenEnabled() {
        var arbiter = openArbiter()
        _ = arbiter.receive(usage: kana, transition: .down, from: .uiKit)
        XCTAssertTrue(arbiter.diagnostics.trace.isEmpty)

        arbiter.setTraceEnabled(true)
        _ = arbiter.receive(usage: kana, transition: .up, from: .uiKit)
        _ = arbiter.receive(usage: a, transition: .down, from: .uiKit)
        _ = arbiter.receive(usage: a, transition: .up, from: .uiKit)
        XCTAssertEqual(arbiter.diagnostics.trace.map(\.usage), [kana])
        XCTAssertEqual(arbiter.diagnostics.trace.first?.outcome, .forwarded)

        arbiter.setTraceEnabled(false)
        XCTAssertTrue(arbiter.diagnostics.trace.isEmpty)
        XCTAssertEqual(arbiter.diagnostics.count(.forwarded), 4)
    }

    func testTheTraceIsBounded() {
        var arbiter = openArbiter()
        arbiter.setTraceEnabled(true)
        for _ in 0..<(InputDiagnostics.traceCapacity + 10) {
            _ = arbiter.receive(usage: leftControl, transition: .down, from: .uiKit)
            _ = arbiter.receive(usage: leftControl, transition: .up, from: .uiKit)
        }
        XCTAssertEqual(arbiter.diagnostics.trace.count, InputDiagnostics.traceCapacity)
    }
}
