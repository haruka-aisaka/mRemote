import XCTest
@testable import SessionCore

final class DisplayScaleTests: XCTestCase {
    func testTheScaleStaysInTheProtocolsRange() {
        XCTAssertEqual(RemoteDisplayScale(percent: 50).desktopPercent, 100)
        XCTAssertEqual(RemoteDisplayScale(percent: 900).desktopPercent, 500)
        XCTAssertEqual(RemoteDisplayScale(percent: 175).desktopPercent, 175)
    }

    func testTheDeviceFactorIsOneTheProtocolAllows() {
        XCTAssertEqual(RemoteDisplayScale(percent: 100).devicePercent, 100)
        XCTAssertEqual(RemoteDisplayScale(percent: 125).devicePercent, 100)
        XCTAssertEqual(RemoteDisplayScale(percent: 150).devicePercent, 140)
        XCTAssertEqual(RemoteDisplayScale(percent: 175).devicePercent, 140)
        XCTAssertEqual(RemoteDisplayScale(percent: 200).devicePercent, 180)
        XCTAssertEqual(RemoteDisplayScale(percent: 300).devicePercent, 180)
    }

    func testAutomaticMatchesTheDevicesOwnScale() {
        XCTAssertEqual(RemoteScalePreference.automatic.resolved(screenScale: 3).desktopPercent, 300)
        XCTAssertEqual(RemoteScalePreference.automatic.resolved(screenScale: 2).desktopPercent, 200)
        XCTAssertEqual(RemoteScalePreference.automatic.resolved(screenScale: 0).desktopPercent, 100)
        XCTAssertEqual(RemoteScalePreference.fixed(150).resolved(screenScale: 3).desktopPercent, 150)
    }

    func testThePreferenceRoundTripsThroughItsStoredText() {
        for preference in [RemoteScalePreference.automatic, .fixed(125), .fixed(300)] {
            XCTAssertEqual(RemoteScalePreference(rawValue: preference.rawValue), preference)
        }
        XCTAssertEqual(RemoteScalePreference(rawValue: "40"), .fixed(100), "clamped, not refused")
        XCTAssertNil(RemoteScalePreference(rawValue: "large"))
    }

    func testAFixedResolutionIgnoresTheScreenAndAnAdaptiveOneFollowsIt() {
        let fixed = ResolutionPolicy.fixed(width: 1_920, height: 1_080)
        XCTAssertEqual(fixed.desktopSize(fitting: (2_000, 1_400))?.width, 1_920)
        XCTAssertEqual(fixed.desktopSize(fitting: nil)?.height, 1_080)
        XCTAssertEqual(ResolutionPolicy.adaptive.desktopSize(fitting: (2_000, 1_400))?.width, 2_000)
        XCTAssertNil(ResolutionPolicy.adaptive.desktopSize(fitting: nil))
    }

    func testEveryPresetIsAFixedSizeTheProtocolAccepts() {
        XCTAssertEqual(Set(ResolutionPolicy.presets).count, ResolutionPolicy.presets.count)
        for preset in ResolutionPolicy.presets {
            guard case let .fixed(width, height) = preset else { return XCTFail("\(preset)") }
            // MS-RDPEDISP: 200...8192, and an even width.
            XCTAssertTrue((200...8_192).contains(width) && (200...8_192).contains(height))
            XCTAssertEqual(width % 2, 0)
        }
    }
}
