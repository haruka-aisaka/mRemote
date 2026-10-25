import XCTest
import SessionCore
@testable import mRemote

/// What the previous version kept on the device, read once to move it into
/// each connection's own setting
/// (docs/changes/2026-10-25-session-settings-writeback.md).
final class ScaleMemoryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var memory: ScaleMemory!

    override func setUp() {
        defaults = UserDefaults(suiteName: "ScaleMemoryTests")!
        defaults.removePersistentDomain(forName: "ScaleMemoryTests")
        memory = ScaleMemory(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "ScaleMemoryTests")
    }

    func testNothingKeptForAConnectionNeverChanged() {
        XCTAssertNil(memory.remembered(for: ProfileID()))
    }

    func testEachConnectionsKeptScaleIsReadBack() {
        let mac = ProfileID(), windows = ProfileID()
        memory.remember(.oneToOne, for: mac)
        memory.remember(.fit, for: windows)
        XCTAssertEqual(ScaleMemory(defaults: defaults).remembered(for: mac), .oneToOne)
        XCTAssertEqual(ScaleMemory(defaults: defaults).remembered(for: windows), .fit)
    }

    func testOnceMovedItIsGone() {
        let profile = ProfileID()
        memory.remember(.oneToOne, for: profile)
        memory.forget(profile)
        XCTAssertNil(memory.remembered(for: profile))
    }
}
