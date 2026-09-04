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
}
