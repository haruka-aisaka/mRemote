import XCTest
import SessionCore
@testable import mRemote

/// The names the resolution pickers show (docs/changes/2026-10-25-resolution-presets.md).
final class ResolutionLabelTests: XCTestCase {
    private func label(_ width: Int, _ height: Int) -> String {
        Formatting.resolutionLabel(.fixed(width: width, height: height))
    }

    func testTheAddedSizesAreNamedByTheirShape() {
        XCTAssertEqual(label(1_600, 1_200), "1600×1200（4:3）")
        XCTAssertEqual(label(2_160, 1_440), "2160×1440（3:2）")
        XCTAssertEqual(label(2_848, 2_004), "2848×2004（iPhone Duo）")
        XCTAssertEqual(label(1_920, 1_352), "1920×1352（iPhone Duo）")
        XCTAssertEqual(label(2_034, 1_398), "2034×1398（iPhone Duo 外側）")
        XCTAssertEqual(label(1_200, 1_600), "1200×1600（3:4）")
        XCTAssertEqual(label(1_440, 2_160), "1440×2160（2:3）")
        XCTAssertEqual(label(1_352, 1_920), "1352×1920（iPhone Duo 縦）")
        XCTAssertEqual(label(1_398, 2_034), "1398×2034（iPhone Duo 外側 縦）")
    }

    func testTheExistingNamesStay() {
        XCTAssertEqual(label(1_920, 1_080), "1920×1080（16:9）")
        XCTAssertEqual(label(1_920, 1_200), "1920×1200（16:10）")
        XCTAssertEqual(label(1_280, 1_024), "1280×1024（5:4）")
        XCTAssertEqual(label(1_024, 768), "1024×768（4:3）")
    }

    func testEveryPresetHasANamedShape() {
        for preset in ResolutionPolicy.presets {
            XCTAssertTrue(Formatting.resolutionLabel(preset).contains("（"), "\(preset)")
        }
    }
}
