import XCTest
import SessionCore
@testable import InputCore

final class KeyShortcutTests: XCTestCase {
    private func keys(_ events: [KeyboardInput]) -> [String] {
        events.map { String(format: "%02X%@", $0.usage, $0.transition == .down ? "v" : "^") }
    }

    func testAShortcutIsAWholeChordInWindowsOrder() {
        let shortcut = KeyShortcut(modifiers: [.alt, .control], usage: 0x4C)
        XCTAssertEqual(keys(shortcut.inputs), ["E0v", "E2v", "4Cv", "4C^", "E2^", "E0^"])
        XCTAssertEqual(shortcut.keysDescription, "Ctrl+Alt+Delete")
        XCTAssertEqual(shortcut.displayTitle, "Ctrl+Alt+Delete")
    }

    func testATitleNamesItWhenGiven() {
        var shortcut = KeyShortcut(title: "  ", modifiers: [.windows], usage: 0x15)
        XCTAssertEqual(shortcut.displayTitle, "Win+R")
        shortcut.title = "ファイル名を指定して実行"
        XCTAssertEqual(shortcut.displayTitle, "ファイル名を指定して実行")
    }

    func testTheListRoundTripsThroughItsStoredString() {
        let list = KeyShortcutList([
            KeyShortcut(title: "a", modifiers: [.shift, .windows], usage: 0x16),
            KeyShortcut(modifiers: [], usage: 0x3A),
        ])
        XCTAssertEqual(KeyShortcutList(rawValue: list.rawValue), list)
        XCTAssertNil(KeyShortcutList(rawValue: "not json"))
    }

    func testEverySuggestionNamesItsKey() {
        for shortcut in KeyShortcut.suggestions {
            XCTAssertNotNil(ShortcutKey.named(usage: shortcut.usage), shortcut.keysDescription)
        }
        XCTAssertEqual(Set(ShortcutKey.all.map(\.usage)).count, ShortcutKey.all.count, "no key is listed twice")
    }
}
