import XCTest
@testable import RDPProtocol

final class ClipboardTextCodecTests: XCTestCase {
    private func units(_ data: Data) -> [UInt16] {
        stride(from: 0, to: data.count, by: 2).map {
            UInt16(data[$0]) | (UInt16(data[$0 + 1]) << 8)
        }
    }

    func testEncodingIsUTF16LEWithCRLFAndOneTrailingNUL() throws {
        let data = try ClipboardTextCodec.encode("a\nあ\r\n😀")
        XCTAssertEqual(units(data), [0x61, 0x0D, 0x0A, 0x3042, 0x0D, 0x0A, 0xD83D, 0xDE00, 0])
    }

    func testEncodingRefusesWhatWindowsWouldTruncate() {
        XCTAssertThrowsError(try ClipboardTextCodec.encode("a\0b")) {
            XCTAssertEqual($0 as? ClipboardTextCodec.EncodingError, .containsNUL)
        }
        XCTAssertThrowsError(try ClipboardTextCodec.encode("")) {
            XCTAssertEqual($0 as? ClipboardTextCodec.EncodingError, .empty)
        }
        let huge = String(repeating: "x", count: ClipboardTextCodec.maximumByteCount / 2)
        XCTAssertThrowsError(try ClipboardTextCodec.encode(huge))
    }

    func testDecodingStopsAtNULAndNormalisesLineEnds() throws {
        let data = Data([0x61, 0, 0x0D, 0, 0x0A, 0, 0x42, 0x30, 0, 0, 0x7A, 0])
        XCTAssertEqual(ClipboardTextCodec.decode(data), "a\nあ")
    }

    func testRoundTripPreservesJapaneseAndEmoji() throws {
        let text = "日本語テキスト\n絵文字 👍🏽 と ASCII"
        XCTAssertEqual(ClipboardTextCodec.decode(try ClipboardTextCodec.encode(text)), text)
    }

    func testAnUnpairedSurrogateDecodesToAReplacement() {
        XCTAssertEqual(ClipboardTextCodec.decode(Data([0x3D, 0xD8, 0x61, 0])), "\u{FFFD}a")
    }
}
