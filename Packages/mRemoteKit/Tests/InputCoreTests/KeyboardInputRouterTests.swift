import XCTest
import SessionCore
@testable import InputCore

final class KeyboardInputRouterTests: XCTestCase {
    /// HID usages used throughout: A is an ordinary repeating key, left shift
    /// is a modifier, and LANG1/LANG2 are the keys this whole app exists for.
    private let a: UInt16 = 0x04
    private let b: UInt16 = 0x05
    private let leftShift: UInt16 = 0xE1
    private let kana: UInt16 = 0x90
    private let eisu: UInt16 = 0x91

    // MARK: - Transitions

    func testAPressAndReleaseAreForwardedOnce() {
        var router = KeyboardInputRouter()
        XCTAssertEqual(
            router.receive(usage: a, transition: .down).events,
            [KeyboardInput(usage: a, transition: .down)]
        )
        XCTAssertEqual(router.pressedUsages, [a])
        XCTAssertEqual(
            router.receive(usage: a, transition: .up).events,
            [KeyboardInput(usage: a, transition: .up)]
        )
        XCTAssertTrue(router.pressedUsages.isEmpty)
    }

    func testADuplicateDownIsDropped() {
        // A second physical down with no up in between means an event was
        // lost, not that the key was pressed twice.
        var router = KeyboardInputRouter()
        _ = router.receive(usage: a, transition: .down)
        XCTAssertEqual(router.receive(usage: a, transition: .down).events, [])
    }

    func testAnOrphanUpIsDropped() {
        // Sending an up the host has no down for can clear a modifier the user
        // is still holding.
        var router = KeyboardInputRouter()
        XCTAssertEqual(router.receive(usage: leftShift, transition: .up).events, [])
    }

    func testSeveralKeysCanBeHeldAtOnce() {
        var router = KeyboardInputRouter()
        _ = router.receive(usage: leftShift, transition: .down)
        _ = router.receive(usage: a, transition: .down)
        XCTAssertEqual(router.pressedUsages, [leftShift, a])
    }

    // MARK: - Release on focus loss

    func testReleaseAllReleasesEveryHeldKey() {
        var router = KeyboardInputRouter()
        _ = router.receive(usage: leftShift, transition: .down)
        _ = router.receive(usage: a, transition: .down)
        let output = router.releaseAll()
        XCTAssertEqual(
            Set(output.events),
            [
                KeyboardInput(usage: a, transition: .up),
                KeyboardInput(usage: leftShift, transition: .up),
            ]
        )
        XCTAssertTrue(router.pressedUsages.isEmpty)
        XCTAssertNil(output.repeatTarget)
    }

    func testReleaseAllIsIdempotent() {
        var router = KeyboardInputRouter()
        _ = router.receive(usage: a, transition: .down)
        XCTAssertEqual(router.releaseAll().events.count, 1)
        XCTAssertEqual(router.releaseAll().events, [])
    }

    func testAKeyReleasedAfterReleaseAllDoesNotSendASecondUp() {
        // The physical up arrives after the app has already released
        // everything; forwarding it would be a second up for one down.
        var router = KeyboardInputRouter()
        _ = router.receive(usage: a, transition: .down)
        _ = router.releaseAll()
        XCTAssertEqual(router.receive(usage: a, transition: .up).events, [])
    }

    // MARK: - Repeat

    func testAHeldKeyRepeatsDownOnly() {
        var router = KeyboardInputRouter()
        let output = router.receive(usage: a, transition: .down)
        XCTAssertTrue(output.restartsRepeat)
        XCTAssertEqual(output.repeatTarget, a)

        let first = router.repeatDown()
        XCTAssertEqual(first, KeyboardInput(usage: a, transition: .down, isRepeat: true))
        // The single up stays bound to the physical release, so the remote
        // never sees a transition it has to unwind.
        XCTAssertEqual(router.repeatDown()?.transition, .down)
    }

    func testRepeatStopsWhenTheKeyIsReleased() {
        var router = KeyboardInputRouter()
        _ = router.receive(usage: a, transition: .down)
        let output = router.receive(usage: a, transition: .up)
        XCTAssertTrue(output.restartsRepeat)
        XCTAssertNil(output.repeatTarget)
        XCTAssertNil(router.repeatDown())
    }

    func testRepeatStopsAfterReleaseAllEvenWithAFireAlreadyPending() {
        var router = KeyboardInputRouter()
        _ = router.receive(usage: a, transition: .down)
        _ = router.releaseAll()
        XCTAssertNil(router.repeatDown())
    }

    func testRepeatFollowsTheNewestKeyAndResumesTheOneStillHeld() {
        var router = KeyboardInputRouter()
        _ = router.receive(usage: a, transition: .down)
        XCTAssertEqual(router.receive(usage: b, transition: .down).repeatTarget, b)
        // Releasing the newest hands the repeat back to the key still down,
        // which is what a physical keyboard does.
        let output = router.receive(usage: b, transition: .up)
        XCTAssertTrue(output.restartsRepeat)
        XCTAssertEqual(output.repeatTarget, a)
    }

    func testAModifierHeldDuringARepeatingKeyDoesNotStealOrRestartIt() {
        var router = KeyboardInputRouter()
        _ = router.receive(usage: a, transition: .down)
        let output = router.receive(usage: leftShift, transition: .down)
        XCTAssertFalse(output.restartsRepeat, "the repeat would restart its initial delay")
        XCTAssertEqual(output.repeatTarget, a)
        XCTAssertEqual(router.repeatDown()?.usage, a)
    }

    func testModifiersAndJapaneseModeKeysNeverRepeat() {
        for usage in [leftShift, kana, eisu, 0x39, 0x53] as [UInt16] {
            var router = KeyboardInputRouter()
            let output = router.receive(usage: usage, transition: .down)
            XCTAssertNil(output.repeatTarget, "usage 0x\(String(usage, radix: 16)) repeated")
            XCTAssertNil(router.repeatDown())
        }
    }

    func testKanaAndEisuSendExactlyOneDownAndOneUp() {
        // docs/input-design.md requires one pair per physical press for these:
        // a repeat would drive the host IME's candidate window rather than
        // type anything.
        for usage in [kana, eisu] {
            var router = KeyboardInputRouter()
            XCTAssertEqual(
                router.receive(usage: usage, transition: .down).events,
                [KeyboardInput(usage: usage, transition: .down)]
            )
            XCTAssertNil(router.repeatDown())
            XCTAssertEqual(
                router.receive(usage: usage, transition: .up).events,
                [KeyboardInput(usage: usage, transition: .up)]
            )
        }
    }

    func testDisabledRepeatArmsNothing() {
        var router = KeyboardInputRouter(repeatSettings: .disabled)
        XCTAssertNil(router.receive(usage: a, transition: .down).repeatTarget)
        XCTAssertNil(router.repeatDown())
    }

    func testTurningRepeatOffStopsAHeldKeyWithoutReleasingIt() {
        var router = KeyboardInputRouter()
        _ = router.receive(usage: a, transition: .down)
        let output = router.setRepeatSettings(.disabled)
        XCTAssertTrue(output.restartsRepeat)
        XCTAssertNil(output.repeatTarget)
        XCTAssertEqual(output.events, [], "the user is still holding the key")
        XCTAssertEqual(router.pressedUsages, [a])
    }
}

final class KeyRepeatSettingsTests: XCTestCase {
    func testIntervalsAreClampedRatherThanTrusted() {
        // A stalled run loop plus a zero interval is an unbounded burst of
        // key-downs.
        let settings = KeyRepeatSettings(initialDelay: 0, interval: -1)
        XCTAssertEqual(settings.initialDelay, KeyRepeatSettings.minimumInterval)
        XCTAssertEqual(settings.interval, KeyRepeatSettings.minimumInterval)
    }
}
