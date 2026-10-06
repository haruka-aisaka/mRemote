import XCTest

/// The Phase 1 exit criterion: list, connect, full screen, back to the list,
/// disconnect. It runs against `FakeRemoteSession` and an in-memory store, so
/// it needs no Windows host and leaves nothing behind.
final class ConnectionFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-mremote-ui-testing"]
        app.launch()
    }

    /// SwiftUI decides for itself whether a row becomes a button, a cell or a
    /// plain element, and that changes between OS versions. Matching on the
    /// identifier across every type keeps the test about the flow rather than
    /// about SwiftUI's current accessibility shape.
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func assertAppears(
        _ identifier: String,
        timeout: TimeInterval = 15,
        _ message: String,
        line: UInt = #line
    ) -> XCUIElement {
        let target = element(identifier)
        XCTAssertTrue(
            target.waitForExistence(timeout: timeout),
            "\(message)\n\(app.debugDescription)",
            file: #filePath,
            line: line
        )
        return target
    }

    func testListConnectWorkspaceReturnAndDisconnect() {
        let row = assertAppears("profile-row-テスト接続先", "the seeded profile should be listed")
        row.tap()

        _ = assertAppears("session-workspace", "connecting presents the full-screen workspace")
        _ = assertAppears("session-status", "the workspace reports the session state")

        element("session-menu-button").tap()
        _ = assertAppears("session-return-to-list", "the floating menu opens")
        element("session-return-to-list").tap()

        // SES-02: leaving the workspace must not disconnect, so the session is
        // still listed as running.
        let running = assertAppears(
            "running-session-テスト接続先",
            "the session stays connected after returning to the list"
        )
        running.tap()

        _ = assertAppears("session-workspace", "a running session can be re-entered")
        element("session-menu-button").tap()
        _ = assertAppears("session-disconnect", "the floating menu opens")
        element("session-disconnect").tap()
        // Disconnecting names the session and asks first; returning does not.
        let confirm = app.buttons["切断"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "disconnect asks for confirmation")
        confirm.tap()

        _ = assertAppears("profile-row-テスト接続先", "disconnecting returns to the list")
        XCTAssertFalse(
            element("running-session-テスト接続先").exists,
            "a disconnected session is no longer running"
        )
    }

    func testAddingAProfileFromTheList() {
        element("add-profile-button").tap()

        let host = assertAppears("profile-host-field", "the editor sheet opens")
        element("profile-name-field").tap()
        app.typeText("新しい接続先")
        host.tap()
        app.typeText("192.168.0.10")

        element("profile-save-button").tap()
        _ = assertAppears("profile-row-新しい接続先", "the saved profile appears in the list")
    }

    func testTheSoftwareKeyboardOpensFromTheMenuAndCloses() {
        element("profile-row-テスト接続先").tap()
        _ = assertAppears("session-workspace", "connecting presents the workspace")
        element("session-menu-button").tap()
        let show = assertAppears("session-show-keyboard", "the menu offers the keyboard")
        show.tap()

        // The extended key bar rides on the keyboard as its accessory view.
        let escape = assertAppears("key-escape", "the extended key bar appears")
        XCTAssertTrue(element("modifier-control").exists)
        XCTAssertTrue(element("software-keyboard-mode").exists)
        XCTAssertTrue(escape.isHittable)

        element("modifier-control").tap()
        XCTAssertEqual(element("modifier-control").value as? String, "次の1キー")
        element("modifier-control").tap()
        XCTAssertEqual(element("modifier-control").value as? String, "固定")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "software-keyboard"
        shot.lifetime = .keepAlways
        add(shot)

        element("software-keyboard-close").tap()
        XCTAssertTrue(
            element("key-escape").waitForNonExistence(timeout: 5),
            "closing removes the bar"
        )
    }

    /// The laptop deck can be forced on from the menu, which is how it is
    /// reached on a device - or a Simulator - that is not folded.
    func testTheLaptopDeckCanBeShownFromTheMenu() {
        element("profile-row-テスト接続先").tap()
        _ = assertAppears("session-workspace", "connecting presents the workspace")
        XCTAssertFalse(element("laptop-deck").exists, "an unfolded screen has no deck")

        element("session-menu-button").tap()
        _ = assertAppears("session-menu", "the floating menu opens")
        let picker = element("session-laptop-deck-picker")
        // The input section sits below the sheet's medium detent.
        for _ in 0..<6 where !(picker.exists && picker.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(picker.isHittable, "the menu offers the deck\n\(app.debugDescription)")
        picker.tap()
        let always = app.buttons["常に表示"].firstMatch
        XCTAssertTrue(always.waitForExistence(timeout: 5), "the picker lists its options")
        always.tap()
        element("session-menu-close").tap()

        _ = assertAppears("laptop-deck", "the deck takes the lower half")
        XCTAssertTrue(element("laptop-trackpad").exists)
        XCTAssertTrue(element("laptop-button-left").exists)
        XCTAssertTrue(element("laptop-key-a").exists)
        XCTAssertTrue(element("laptop-key-kana").exists, "the seeded profile is Japanese")
        XCTAssertTrue(element("session-menu-button").isHittable, "the menu stays reachable above the deck")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "laptop-deck"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
