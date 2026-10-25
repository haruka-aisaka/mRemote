import XCTest
import SessionCore
@testable import mRemote

/// Each connection opens at the scale it was last viewed at
/// (docs/changes/2026-10-25-remember-scale.md).
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

    func testAConnectionNeverChangedOpensFitted() {
        XCTAssertEqual(memory.scale(for: ProfileID()), .fit)
        XCTAssertEqual(memory.scale(for: nil), .fit)
    }

    func testEachConnectionKeepsItsOwnScale() {
        let mac = ProfileID(), windows = ProfileID()
        memory.remember(.oneToOne, for: mac)
        memory.remember(.fit, for: windows)
        XCTAssertEqual(memory.scale(for: mac), .oneToOne)
        XCTAssertEqual(memory.scale(for: windows), .fit)
        memory.remember(.fit, for: mac)
        XCTAssertEqual(memory.scale(for: mac), .fit)
    }

    func testItOutlivesTheObjectThatWroteIt() {
        let profile = ProfileID()
        memory.remember(.oneToOne, for: profile)
        XCTAssertEqual(ScaleMemory(defaults: defaults).scale(for: profile), .oneToOne)
    }

    func testACopyStartsWhereTheOriginalWas() {
        let original = ProfileID(), copy = ProfileID(), untouched = ProfileID()
        memory.remember(.oneToOne, for: original)
        memory.copy(from: original, to: copy)
        memory.copy(from: untouched, to: ProfileID())
        XCTAssertEqual(memory.scale(for: copy), .oneToOne)
    }

    func testADeletedConnectionIsForgotten() {
        let profile = ProfileID()
        memory.remember(.oneToOne, for: profile)
        memory.forget(profile)
        XCTAssertEqual(memory.scale(for: profile), .fit)
    }
}
