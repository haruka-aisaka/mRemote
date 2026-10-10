import XCTest

/// One keyboard at a time, and the keyboard button brings back the one used
/// last. Runs against `FakeRemoteSession`, like `ConnectionFlowUITests`.
final class KeyboardToggleUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-mremote-ui-testing"]
        app.launch()
        element("profile-row-テスト接続先").tap()
        XCTAssertTrue(element("session-workspace").waitForExistence(timeout: 15))
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private var keyButton: XCUIElement { element("session-keyboard-button") }

    /// The iOS keyboard counts as up when its key bar is.
    private var softwareKeyboardUp: Bool { element("key-escape").exists }
    private var deckUp: Bool { element("laptop-deck").exists }

    /// Waits for things to settle, then checks exactly what is on screen and
    /// that the button says so.
    private func assertShowing(
        software: Bool,
        deck: Bool,
        _ message: String,
        line: UInt = #line
    ) {
        let settled = expectation(for: NSPredicate { [self] _, _ in
            softwareKeyboardUp == software && deckUp == deck
        }, evaluatedWith: nil)
        let result = XCTWaiter().wait(for: [settled], timeout: 5)
        // Long enough for a keyboard brought back late to show up.
        Thread.sleep(forTimeInterval: 1.5)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = message
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertEqual(result, .completed, "\(message): software=\(softwareKeyboardUp) deck=\(deckUp)", line: line)
        XCTAssertEqual(softwareKeyboardUp, software, "\(message): iOS keyboard", line: line)
        XCTAssertEqual(deckUp, deck, "\(message): deck", line: line)
        let label = keyButton.label
        XCTAssertEqual(
            label, software || deck ? "キーボードを隠す" : "キーボードを表示",
            "\(message): the button's state", line: line
        )
    }

    private func menu(_ item: String) {
        element("session-menu-button").tap()
        let target = element(item)
        XCTAssertTrue(target.waitForExistence(timeout: 5), "the menu offers \(item)")
        target.tap()
    }

    /// The deck chosen from the menu while the iOS keyboard is up replaces it:
    /// the system must not bring the iOS keyboard back as the sheet goes.
    func testTheDeckFromTheMenuReplacesTheKeyboard() {
        keyButton.tap()
        assertShowing(software: true, deck: false, "button: iOS keyboard")
        menu("session-toggle-laptop-deck")
        assertShowing(software: false, deck: true, "menu: deck replaces it")
        keyButton.tap()
        assertShowing(software: false, deck: false, "button: deck away")
        keyButton.tap()
        assertShowing(software: false, deck: true, "button: the deck again, the one used last")
    }

    /// And the other way round.
    func testTheKeyboardFromTheMenuReplacesTheDeck() {
        menu("session-toggle-laptop-deck")
        assertShowing(software: false, deck: true, "menu: deck")
        menu("session-show-keyboard")
        assertShowing(software: true, deck: false, "menu: iOS keyboard replaces it")
        keyButton.tap()
        assertShowing(software: false, deck: false, "button: keyboard away")
        keyButton.tap()
        assertShowing(software: true, deck: false, "button: the iOS keyboard again, the one used last")
    }

    /// Opening and closing the menu leaves the keyboard as it was, and the
    /// button agrees with what is on screen.
    func testTheMenuLeavesTheKeyboardAsItWas() {
        keyButton.tap()
        assertShowing(software: true, deck: false, "button: iOS keyboard")
        element("session-menu-button").tap()
        XCTAssertTrue(element("session-menu-close").waitForExistence(timeout: 5))
        element("session-menu-close").tap()
        XCTAssertTrue(element("session-menu-close").waitForNonExistence(timeout: 5))
        let up = softwareKeyboardUp
        assertShowing(software: up, deck: false, "after the menu")
        keyButton.tap()
        assertShowing(software: !up, deck: false, "button after the menu")
    }

    /// Closed from its own bar, the keyboard is gone for the button too.
    func testClosingFromTheBarIsSeenByTheButton() {
        keyButton.tap()
        assertShowing(software: true, deck: false, "button: iOS keyboard")
        element("software-keyboard-close").tap()
        assertShowing(software: false, deck: false, "bar: closed")
        keyButton.tap()
        assertShowing(software: true, deck: false, "button: back")
    }
}
