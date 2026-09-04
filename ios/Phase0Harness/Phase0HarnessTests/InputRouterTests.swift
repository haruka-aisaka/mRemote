import XCTest
#if SWIFT_PACKAGE
@testable import Phase0HarnessLogic
#else
@testable import Phase0Harness
#endif

@MainActor
final class InputRouterTests: XCTestCase {
    func testUIKitPolicyDropsDelayedGCEvents() {
        let context = makeContext()
        context.router.keyboard.receive(key(.down, source: .uiKit))
        context.router.keyboard.receive(key(.up, source: .uiKit))
        context.router.keyboard.receive(key(.down, source: .gameController))
        context.router.keyboard.receive(key(.up, source: .gameController))

        XCTAssertEqual(context.sink.events.map { $0.0 }, [
            .hardwareKey(usage: HIDUsage.eisu, transition: .down),
            .hardwareKey(usage: HIDUsage.eisu, transition: .up),
        ])
        XCTAssertEqual(context.journal.counters.dropped, 2)
    }

    func testDuplicateDownAndOrphanUpAreNotForwarded() {
        let context = makeContext()
        context.router.keyboard.receive(key(.down))
        context.router.keyboard.receive(key(.down))
        context.router.keyboard.receive(key(.up))
        context.router.keyboard.receive(key(.up))

        XCTAssertEqual(context.sink.events.map { $0.0 }, [
            .hardwareKey(usage: HIDUsage.eisu, transition: .down),
            .hardwareKey(usage: HIDUsage.eisu, transition: .up),
        ])
    }

    func testJapaneseOnlyPolicyUsesGCWithoutChangingOrdinaryKeys() {
        let context = makeContext()
        context.router.keyboard.requestGCForJapanesePolicy()
        context.router.keyboard.receive(key(.down, usage: HIDUsage.kana, source: .uiKit))
        context.router.keyboard.receive(key(.up, usage: HIDUsage.kana, source: .uiKit))
        context.router.keyboard.receive(key(.down, usage: HIDUsage.kana, source: .gameController))
        context.router.keyboard.receive(key(.up, usage: HIDUsage.kana, source: .gameController))
        context.router.keyboard.receive(key(.down, usage: 0x04, source: .uiKit))
        context.router.keyboard.receive(key(.up, usage: 0x04, source: .uiKit))

        XCTAssertEqual(context.sink.events.map { $0.0 }, [
            .hardwareKey(usage: HIDUsage.kana, transition: .down),
            .hardwareKey(usage: HIDUsage.kana, transition: .up),
            .hardwareKey(usage: 0x04, transition: .down),
            .hardwareKey(usage: 0x04, transition: .up),
        ])
    }

    func testPrintableHardwareEventsAreCountedWithoutJournalLines() {
        let context = makeContext()
        context.router.keyboard.receive(key(.down, usage: 0x04, source: .uiKit))
        context.router.keyboard.receive(key(.up, usage: 0x04, source: .uiKit))

        XCTAssertEqual(context.journal.counters.observed, 2)
        XCTAssertEqual(context.journal.counters.sent, 2)
        XCTAssertTrue(context.journal.lines.isEmpty)

        let exported = context.journal.exportText(environmentNotes: "printable privacy")
        for forbidden in ["KeyboardA", "0x04", "HID=", "set1=", " down", " up"] {
            XCTAssertFalse(exported.contains(forbidden), "export leaked \(forbidden)")
        }
    }

    func testPrintableHardwareDropsAreCountedWithoutJournalLines() {
        let context = makeContext(hardwareGateInitiallyOpen: false)
        context.router.keyboard.receive(key(.down, usage: 0x05, source: .uiKit))
        context.router.keyboard.receive(key(.up, usage: 0x05, source: .uiKit))

        XCTAssertEqual(context.journal.counters.observed, 2)
        XCTAssertEqual(context.journal.counters.dropped, 2)
        XCTAssertTrue(context.journal.lines.isEmpty)
    }

    func testEisuAndKanaCanSelectIndependentSources() {
        let context = makeContext()
        context.router.keyboard.requestJapanesePolicy(
            eisu: .uiKit,
            kana: .gameController
        )
        context.router.keyboard.receive(key(.down, usage: HIDUsage.eisu, source: .uiKit))
        context.router.keyboard.receive(key(.up, usage: HIDUsage.eisu, source: .uiKit))
        context.router.keyboard.receive(key(.down, usage: HIDUsage.kana, source: .gameController))
        context.router.keyboard.receive(key(.up, usage: HIDUsage.kana, source: .gameController))

        XCTAssertEqual(context.sink.events.map { $0.0 }, [
            .hardwareKey(usage: HIDUsage.eisu, transition: .down),
            .hardwareKey(usage: HIDUsage.eisu, transition: .up),
            .hardwareKey(usage: HIDUsage.kana, transition: .down),
            .hardwareKey(usage: HIDUsage.kana, transition: .up),
        ])
    }

    func testUnsupportedJapaneseUsageIsObservedButNeverSent() {
        let context = makeContext()
        context.router.keyboard.requestJapanesePolicy(eisu: nil, kana: .uiKit)
        context.router.keyboard.receive(key(.down, usage: HIDUsage.eisu, source: .uiKit))
        context.router.keyboard.receive(key(.up, usage: HIDUsage.eisu, source: .uiKit))
        context.router.keyboard.receive(key(.down, usage: HIDUsage.eisu, source: .gameController))
        context.router.keyboard.receive(key(.up, usage: HIDUsage.eisu, source: .gameController))

        XCTAssertTrue(context.sink.events.isEmpty)
        XCTAssertEqual(context.journal.counters.observed, 4)
        XCTAssertEqual(context.journal.counters.dropped, 4)
    }

    func testReleaseAllSendsUpAndQuarantinesPhysicalTail() {
        let context = makeContext()
        context.router.keyboard.receive(key(.down))
        context.router.keyboard.releaseAll(reason: "test")
        context.router.keyboard.receive(key(.up))

        XCTAssertEqual(context.sink.events.map { $0.0 }, [
            .hardwareKey(usage: HIDUsage.eisu, transition: .down),
            .hardwareKey(usage: HIDUsage.eisu, transition: .up),
        ])

        context.router.keyboard.receive(key(.down))
        context.router.keyboard.receive(key(.up))
        XCTAssertEqual(context.sink.events.count, 4, "the next complete cycle must be accepted")
    }

    func testKeyboardQuarantineWaitsForDelayedSecondaryAfterSelectedUp() {
        let context = makeContext()
        context.router.keyboard.receive(key(.down, source: .uiKit))
        context.router.keyboard.receive(key(.down, source: .gameController))
        context.router.keyboard.releaseAll(reason: "test")

        context.router.keyboard.receive(key(.up, source: .uiKit))
        context.router.keyboard.receive(key(.down, source: .uiKit))
        context.router.keyboard.receive(key(.up, source: .uiKit))
        context.router.keyboard.receive(key(.up, source: .gameController))
        context.router.keyboard.receive(key(.down, source: .uiKit))
        context.router.keyboard.receive(key(.up, source: .uiKit))

        XCTAssertEqual(context.sink.events.map { $0.0 }, [
            .hardwareKey(usage: HIDUsage.eisu, transition: .down),
            .hardwareKey(usage: HIDUsage.eisu, transition: .up),
            .hardwareKey(usage: HIDUsage.eisu, transition: .down),
            .hardwareKey(usage: HIDUsage.eisu, transition: .up),
        ])
    }

    func testKeyboardQuarantineWaitsForSelectedSourceAfterSecondaryUp() {
        let context = makeContext()
        context.router.keyboard.receive(key(.down, source: .uiKit))
        context.router.keyboard.receive(key(.down, source: .gameController))
        context.router.keyboard.releaseAll(reason: "test")

        context.router.keyboard.receive(key(.up, source: .gameController))
        context.router.keyboard.receive(key(.down, source: .gameController))
        context.router.keyboard.receive(key(.up, source: .gameController))
        context.router.keyboard.receive(key(.up, source: .uiKit))
        context.router.keyboard.receive(key(.down, source: .uiKit))
        context.router.keyboard.receive(key(.up, source: .uiKit))

        XCTAssertEqual(context.sink.events.map { $0.0 }, [
            .hardwareKey(usage: HIDUsage.eisu, transition: .down),
            .hardwareKey(usage: HIDUsage.eisu, transition: .up),
            .hardwareKey(usage: HIDUsage.eisu, transition: .down),
            .hardwareKey(usage: HIDUsage.eisu, transition: .up),
        ])
    }

    func testKeyboardDisconnectReevaluatesNeutralQuarantine() {
        let context = makeContext()
        context.router.keyboard.receive(key(.down, source: .gameController))
        context.router.keyboard.keyboardDisconnected()
        context.router.keyboard.receive(key(.down, source: .uiKit))
        context.router.keyboard.receive(key(.up, source: .uiKit))

        XCTAssertEqual(context.sink.events.map { $0.0 }, [
            .hardwareKey(usage: HIDUsage.eisu, transition: .down),
            .hardwareKey(usage: HIDUsage.eisu, transition: .up),
        ])
    }

    func testPendingKeyboardPolicyQuarantinesDelayedNewSourceTail() {
        let context = makeContext()
        context.router.keyboard.receive(key(.down, source: .uiKit))
        context.router.keyboard.releaseAll(reason: "local route control")
        context.router.keyboard.requestGCForJapanesePolicy()
        context.router.keyboard.receive(key(.up, source: .uiKit))

        // This secondary observation belongs to the released UIKit cycle. It
        // must not become a new remote cycle merely because GC is now selected.
        context.router.keyboard.receive(key(.down, source: .gameController))
        context.router.keyboard.receive(key(.up, source: .gameController))
        context.router.keyboard.receive(key(.down, source: .gameController))
        context.router.keyboard.receive(key(.up, source: .gameController))

        XCTAssertEqual(context.sink.events.map { $0.0 }, [
            .hardwareKey(usage: HIDUsage.eisu, transition: .down),
            .hardwareKey(usage: HIDUsage.eisu, transition: .up),
            .hardwareKey(usage: HIDUsage.eisu, transition: .down),
            .hardwareKey(usage: HIDUsage.eisu, transition: .up),
        ])
    }

    func testPendingKeyboardPolicyWithoutReleaseAllDrainsDelayedNewSourceCycle() {
        let context = makeContext()
        context.router.keyboard.receive(key(.down, source: .uiKit))
        context.router.keyboard.requestGCForJapanesePolicy()
        context.router.keyboard.receive(key(.up, source: .uiKit))

        context.router.keyboard.receive(key(.down, source: .gameController))
        context.router.keyboard.receive(key(.up, source: .gameController))
        context.router.keyboard.receive(key(.down, source: .gameController))
        context.router.keyboard.receive(key(.up, source: .gameController))

        XCTAssertEqual(context.sink.events.map { $0.0 }, [
            .hardwareKey(usage: HIDUsage.eisu, transition: .down),
            .hardwareKey(usage: HIDUsage.eisu, transition: .up),
            .hardwareKey(usage: HIDUsage.eisu, transition: .down),
            .hardwareKey(usage: HIDUsage.eisu, transition: .up),
        ])
    }

    func testKeyboardSwitchDrainIgnoresExtraUpsBeforeDelayedNewSourceCycle() {
        let context = makeContext()
        context.router.keyboard.receive(key(.down, source: .uiKit))
        context.router.keyboard.requestGCForJapanesePolicy()
        context.router.keyboard.receive(key(.up, source: .uiKit))

        context.router.keyboard.receive(key(.up, source: .uiKit))
        context.router.keyboard.receive(key(.up, source: .gameController))
        context.router.keyboard.receive(key(.down, source: .gameController))
        context.router.keyboard.receive(key(.up, source: .gameController))
        context.router.keyboard.receive(key(.down, source: .gameController))
        context.router.keyboard.receive(key(.up, source: .gameController))

        XCTAssertEqual(context.sink.events.map { $0.0 }, [
            .hardwareKey(usage: HIDUsage.eisu, transition: .down),
            .hardwareKey(usage: HIDUsage.eisu, transition: .up),
            .hardwareKey(usage: HIDUsage.eisu, transition: .down),
            .hardwareKey(usage: HIDUsage.eisu, transition: .up),
        ])
    }

    func testPendingKeyboardPolicyTracksSecondUsage() {
        let context = makeContext()
        let secondUsage = HIDUsage.kana
        context.router.keyboard.receive(key(.down, source: .uiKit))
        context.router.keyboard.requestGCForJapanesePolicy()
        context.router.keyboard.receive(key(.down, usage: secondUsage, source: .uiKit))
        context.router.keyboard.receive(key(.up, source: .uiKit))
        context.router.keyboard.receive(key(.up, usage: secondUsage, source: .uiKit))

        for usage in [HIDUsage.eisu, secondUsage] {
            context.router.keyboard.receive(key(.down, usage: usage, source: .gameController))
            context.router.keyboard.receive(key(.up, usage: usage, source: .gameController))
            context.router.keyboard.receive(key(.down, usage: usage, source: .gameController))
            context.router.keyboard.receive(key(.up, usage: usage, source: .gameController))
        }

        XCTAssertEqual(
            context.sink.events.map { $0.0 },
            [
                .hardwareKey(usage: HIDUsage.eisu, transition: .down),
                .hardwareKey(usage: secondUsage, transition: .down),
                .hardwareKey(usage: HIDUsage.eisu, transition: .up),
                .hardwareKey(usage: secondUsage, transition: .up),
                .hardwareKey(usage: HIDUsage.eisu, transition: .down),
                .hardwareKey(usage: HIDUsage.eisu, transition: .up),
                .hardwareKey(usage: secondUsage, transition: .down),
                .hardwareKey(usage: secondUsage, transition: .up),
            ]
        )
    }

    func testPointerPolicyForwardsOnlySelectedSource() {
        let context = makeContext()
        context.router.pointer.receive(pointer(.move(remote: CGPoint(x: 3, y: 4)), source: .uiKit))
        context.router.pointer.receive(pointer(.move(remote: CGPoint(x: 7, y: 8)), source: .gameController))
        context.router.pointer.requestSource(.gameController)
        context.router.pointer.receive(pointer(.scroll(horizontal: 1, vertical: -2), source: .uiKit))
        context.router.pointer.receive(pointer(.scroll(horizontal: 3, vertical: -4), source: .gameController))

        XCTAssertEqual(context.sink.events.map { $0.0 }, [
            .pointer(.move(remote: CGPoint(x: 3, y: 4))),
            .pointer(.scroll(horizontal: 3, vertical: -4)),
        ])
    }

    func testPointerScrollRetainsFractionsPerAxisAndDirection() {
        let context = makeContext()

        context.router.pointer.receive(
            pointer(.scroll(horizontal: 0.75, vertical: -0.25), source: .uiKit)
        )
        context.router.pointer.receive(
            pointer(.scroll(horizontal: 0.25, vertical: -0.75), source: .uiKit)
        )
        context.router.pointer.receive(
            pointer(.scroll(horizontal: -0.5, vertical: 0.75), source: .uiKit)
        )
        context.router.pointer.receive(
            pointer(.scroll(horizontal: -0.5, vertical: 0.25), source: .uiKit)
        )

        XCTAssertEqual(context.sink.events.map(\.0), [
            .pointer(.scroll(horizontal: 1, vertical: -1)),
            .pointer(.scroll(horizontal: -1, vertical: 1)),
        ])
    }

    func testPointerScrollDirectionChangeResetsResidualAndInvertsBothAxes() {
        let context = makeContext()
        context.router.pointer.receive(
            pointer(.scroll(horizontal: 0.75, vertical: -0.75), source: .uiKit)
        )

        context.router.pointer.setScrollDirection(.reversed)
        context.router.pointer.receive(
            pointer(.scroll(horizontal: 0.25, vertical: -0.25), source: .uiKit)
        )
        context.router.pointer.receive(
            pointer(.scroll(horizontal: 0.75, vertical: -0.75), source: .uiKit)
        )

        XCTAssertEqual(context.sink.events.map(\.0), [
            .pointer(.scroll(horizontal: -1, vertical: 1)),
        ])
    }

    func testPointerReleaseAndSourceSwitchResetScrollResiduals() {
        let context = makeContext()
        context.router.pointer.receive(
            pointer(.scroll(horizontal: 0.75, vertical: 0), source: .uiKit)
        )

        context.router.pointer.releaseAll(reason: "lifecycle boundary")
        context.router.pointer.receive(
            pointer(.scroll(horizontal: 0.25, vertical: 0), source: .uiKit)
        )
        context.router.pointer.receive(
            pointer(.scroll(horizontal: 0.75, vertical: 0), source: .uiKit)
        )
        context.router.pointer.receive(
            pointer(.scroll(horizontal: 0.75, vertical: 0), source: .uiKit)
        )

        context.router.pointer.requestSource(.gameController)
        context.router.pointer.receive(
            pointer(.scroll(horizontal: 0.25, vertical: 0), source: .gameController)
        )
        context.router.pointer.receive(
            pointer(.scroll(horizontal: 0.75, vertical: 0), source: .gameController)
        )

        XCTAssertEqual(context.sink.events.map(\.0), [
            .pointer(.scroll(horizontal: 1, vertical: 0)),
            .pointer(.scroll(horizontal: 1, vertical: 0)),
        ])
    }

    func testPointerQuarantineWaitsUntilBothSourcesReportButtonUp() {
        let context = makeContext()
        let remote = CGPoint(x: 10, y: 20)
        context.router.pointer.receive(pointer(.button(.left, .down, remote: remote), source: .uiKit))
        context.router.pointer.receive(pointer(.button(.left, .down, remote: remote), source: .gameController))
        context.router.pointer.releaseAll(reason: "test")

        context.router.pointer.receive(pointer(.button(.left, .up, remote: remote), source: .uiKit))
        context.router.pointer.receive(pointer(.button(.left, .down, remote: remote), source: .uiKit))
        context.router.pointer.receive(pointer(.button(.left, .up, remote: remote), source: .uiKit))
        context.router.pointer.receive(pointer(.button(.left, .up, remote: remote), source: .gameController))
        context.router.pointer.receive(pointer(.button(.left, .down, remote: remote), source: .uiKit))
        context.router.pointer.receive(pointer(.button(.left, .up, remote: remote), source: .uiKit))

        XCTAssertEqual(context.sink.events.map { $0.0 }, [
            .pointer(.button(.left, .down, remote: remote)),
            .pointer(.button(.left, .up, remote: nil)),
            .pointer(.button(.left, .down, remote: remote)),
            .pointer(.button(.left, .up, remote: remote)),
        ])
    }

    func testPendingPointerSourceQuarantinesDelayedTailAndDropsOldStatelessEvents() {
        let context = makeContext()
        let remote = CGPoint(x: 10, y: 20)
        let moved = CGPoint(x: 30, y: 40)
        context.router.pointer.receive(
            pointer(.button(.left, .down, remote: remote), source: .uiKit)
        )
        context.router.pointer.releaseAll(reason: "local route control")
        context.router.pointer.requestSource(.gameController)
        context.router.pointer.receive(
            pointer(.button(.left, .up, remote: remote), source: .uiKit)
        )

        // The GCMouse tail is the second observation of the released UIKit
        // click, not a new click in the newly selected source epoch.
        context.router.pointer.receive(
            pointer(.button(.left, .down, remote: remote), source: .gameController)
        )
        context.router.pointer.receive(
            pointer(.button(.left, .up, remote: remote), source: .gameController)
        )
        context.router.pointer.receive(pointer(.move(remote: moved), source: .uiKit))
        context.router.pointer.receive(
            pointer(.scroll(horizontal: 1, vertical: -2), source: .uiKit)
        )
        context.router.pointer.receive(pointer(.move(remote: moved), source: .gameController))
        context.router.pointer.receive(
            pointer(.scroll(horizontal: 3, vertical: -4), source: .gameController)
        )
        context.router.pointer.receive(
            pointer(.button(.left, .down, remote: remote), source: .gameController)
        )
        context.router.pointer.receive(
            pointer(.button(.left, .up, remote: remote), source: .gameController)
        )

        XCTAssertEqual(context.sink.events.map { $0.0 }, [
            .pointer(.button(.left, .down, remote: remote)),
            .pointer(.button(.left, .up, remote: nil)),
            .pointer(.move(remote: moved)),
            .pointer(.scroll(horizontal: 3, vertical: -4)),
            .pointer(.button(.left, .down, remote: remote)),
            .pointer(.button(.left, .up, remote: remote)),
        ])
    }

    func testPendingPointerSourceTracksSecondButtonAndDrainsGesturesUntilUp() {
        let context = makeContext()
        let remote = CGPoint(x: 10, y: 20)
        let moved = CGPoint(x: 30, y: 40)
        context.router.pointer.receive(
            pointer(.button(.left, .down, remote: remote), source: .uiKit)
        )
        context.router.pointer.requestSource(.gameController)
        context.router.pointer.receive(
            pointer(.button(.right, .down, remote: remote), source: .uiKit)
        )
        context.router.pointer.receive(
            pointer(.button(.left, .up, remote: remote), source: .uiKit)
        )
        context.router.pointer.receive(
            pointer(.button(.right, .up, remote: remote), source: .uiKit)
        )

        context.router.pointer.receive(
            pointer(.button(.left, .down, remote: remote), source: .gameController)
        )
        context.router.pointer.receive(pointer(.move(remote: moved), source: .gameController))
        context.router.pointer.receive(
            pointer(.scroll(horizontal: 3, vertical: -4), source: .gameController)
        )
        context.router.pointer.receive(
            pointer(.button(.left, .up, remote: remote), source: .gameController)
        )
        context.router.pointer.receive(
            pointer(.button(.right, .down, remote: remote), source: .gameController)
        )
        context.router.pointer.receive(
            pointer(.button(.right, .up, remote: remote), source: .gameController)
        )
        context.router.pointer.receive(pointer(.move(remote: moved), source: .gameController))

        XCTAssertEqual(context.sink.events.map { $0.0 }, [
            .pointer(.button(.left, .down, remote: remote)),
            .pointer(.button(.right, .down, remote: remote)),
            .pointer(.button(.left, .up, remote: remote)),
            .pointer(.button(.right, .up, remote: remote)),
            .pointer(.move(remote: moved)),
        ])
    }

    func testMouseDisconnectReevaluatesNeutralQuarantine() {
        let context = makeContext()
        let remote = CGPoint(x: 4, y: 5)
        context.router.pointer.receive(pointer(.button(.right, .down, remote: remote), source: .gameController))
        context.router.pointer.mouseDisconnected()
        context.router.pointer.receive(pointer(.button(.right, .down, remote: remote), source: .uiKit))
        context.router.pointer.receive(pointer(.button(.right, .up, remote: remote), source: .uiKit))

        XCTAssertEqual(context.sink.events.map { $0.0 }, [
            .pointer(.button(.right, .down, remote: remote)),
            .pointer(.button(.right, .up, remote: remote)),
        ])
    }

    func testClosedHardwareGateDropsAllSourcesUntilReopened() {
        let context = makeContext()
        context.router.setHardwareGate(open: false, reason: "inactive")
        XCTAssertFalse(context.router.isHardwareGateOpen)

        context.router.keyboard.receive(key(.down, source: .gameController))
        context.router.pointer.receive(pointer(.move(remote: CGPoint(x: 8, y: 9)), source: .gameController))
        XCTAssertTrue(context.sink.events.isEmpty)

        context.router.setHardwareGate(open: true, reason: "active hardware mode")
        context.router.keyboard.receive(key(.up, source: .gameController))
        context.router.keyboard.receive(key(.down, source: .uiKit))
        context.router.keyboard.receive(key(.up, source: .uiKit))
        context.router.pointer.receive(pointer(.move(remote: CGPoint(x: 1, y: 2)), source: .uiKit))

        XCTAssertTrue(context.router.isHardwareGateOpen)
        XCTAssertEqual(context.sink.events.map { $0.0 }, [
            .hardwareKey(usage: HIDUsage.eisu, transition: .down),
            .hardwareKey(usage: HIDUsage.eisu, transition: .up),
            .pointer(.move(remote: CGPoint(x: 1, y: 2))),
        ])
    }

    func testRouterCanStartClosedUntilSurfaceCaptureSucceeds() {
        let context = makeContext(hardwareGateInitiallyOpen: false)
        context.router.keyboard.receive(key(.down))
        XCTAssertFalse(context.router.isHardwareGateOpen)
        XCTAssertTrue(context.sink.events.isEmpty)

        context.router.setHardwareGate(open: true, reason: "surface captured")
        context.router.keyboard.receive(key(.up))
        context.router.keyboard.receive(key(.down))
        context.router.keyboard.receive(key(.up))
        XCTAssertEqual(context.sink.events.map { $0.0 }, [
            .hardwareKey(usage: HIDUsage.eisu, transition: .down),
            .hardwareKey(usage: HIDUsage.eisu, transition: .up),
        ])
    }

    private func makeContext(hardwareGateInitiallyOpen: Bool = true) -> (
        journal: EventJournal,
        sink: RecordingInputSink,
        router: HarnessInputRouter
    ) {
        let journal = EventJournal()
        let sink = RecordingInputSink(journal: journal)
        return (
            journal,
            sink,
            HarnessInputRouter(
                sink: sink,
                journal: journal,
                hardwareGateInitiallyOpen: hardwareGateInitiallyOpen
            )
        )
    }

    private func key(
        _ transition: KeyTransition,
        usage: UInt16 = HIDUsage.eisu,
        source: KeyboardEventSource = .uiKit
    ) -> HardwareKeyEvent {
        HardwareKeyEvent(
            usage: usage,
            transition: transition,
            source: source,
            uptime: 1
        )
    }

    private func pointer(
        _ payload: PointerPayload,
        source: PointerEventSource
    ) -> PointerInputEvent {
        PointerInputEvent(payload: payload, source: source, uptime: 1)
    }
}
