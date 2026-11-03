import XCTest

/// docs/changes/2026-11-03-deck-trackpad-and-home-bar.md: the deck's keys
/// put away with one tap, keys that keep their shape, a pad that goes when
/// there is no room for it, and a home indicator that stays away. Runs
/// against `FakeRemoteSession`, like `ConnectionFlowUITests`.
final class DeckTrackpadUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["-mremote-ui-testing"]
        app.launch()
        connect()
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func connect() {
        element("profile-row-テスト接続先").tap()
        XCTAssertTrue(element("session-workspace").waitForExistence(timeout: 15))
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private var workspaceState: String {
        element("session-workspace").value as? String ?? ""
    }

    private func snapshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func menu(_ item: String) {
        element("session-menu-button").tap()
        XCTAssertTrue(element("session-menu").waitForExistence(timeout: 5), "the menu opens")
        let target = element(item)
        // Rows below the sheet's medium detent are not built until scrolled to.
        scrollMenu(to: target)
        XCTAssertTrue(target.isHittable, "the menu offers \(item)")
        target.tap()
    }

    /// Drags in the sheet's left margin, as ConnectionFlowUITests does: one
    /// through the middle can land on a picker and press it.
    private func scrollMenu(to target: XCUIElement) {
        let menu = element("session-menu")
        // Wholly inside the sheet: a row half past its foot counts as
        // hittable, and a tap on the half outside closes the sheet.
        func clear() -> Bool {
            target.exists && target.isHittable && target.frame.maxY <= menu.frame.maxY - 8
        }
        for _ in 0..<8 where !clear() {
            menu.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: menu.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.3)))
        }
    }

    private func showDeck() {
        menu("session-toggle-laptop-deck")
        XCTAssertTrue(element("laptop-deck").waitForExistence(timeout: 5), "the deck comes up")
    }

    private func waitFor(_ condition: @escaping () -> Bool, _ message: String, line: UInt = #line) {
        let settled = expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [settled], timeout: 5), .completed, message, line: line)
    }

    private var keysUp: Bool { element("laptop-key-a").exists }
    private var padUp: Bool { element("laptop-trackpad").exists }

    /// One tap puts the keys away and the pad takes the deck; another brings
    /// them back. The deck itself does not move.
    func testTheToggleTradesTheKeysForAWholeDeckPad() {
        showDeck()
        let deck = element("laptop-deck")
        let toggle = element("deck-keys-toggle")
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the toggle leads the shortcut strip")
        XCTAssertEqual(toggle.label, "キーボードを隠してトラックパッドを広げる")
        let deckFrame = deck.frame
        let smallPad = element("laptop-trackpad").frame
        // The keys span the deck less its side safe area (the iPhone Duo's
        // Simulator has one), each cap inset by half the 4-point gap.
        let keysLeft = element("laptop-key-esc").frame.minX - 2
        let keysRight = element("laptop-key-delete").frame.maxX + 2
        snapshot("keys and pad")

        toggle.tap()
        waitFor({ !self.keysUp }, "the keys go")
        XCTAssertTrue(padUp)
        let bigPad = element("laptop-trackpad").frame
        XCTAssertEqual(deck.frame, deckFrame, "the deck keeps its place and height")
        XCTAssertGreaterThan(bigPad.height, smallPad.height + 100, "the pad takes the keys' room")
        XCTAssertEqual(bigPad.minX, keysLeft, accuracy: 1, "the pad spans the keys' width")
        XCTAssertEqual(bigPad.maxX, keysRight, accuracy: 1, "the pad spans the keys' width")
        XCTAssertEqual(toggle.label, "キーボードを表示")
        XCTAssertTrue(workspaceState.contains("deckPad=true"), workspaceState)
        snapshot("pad only")

        toggle.tap()
        waitFor({ self.keysUp }, "the keys come back")
        XCTAssertEqual(element("laptop-trackpad").frame, smallPad)
    }

    /// Keys held or latched as they go would stay down on the host.
    func testPuttingTheKeysAwayLetsGoOfALatchedModifier() {
        showDeck()
        let shift = element("laptop-key-shift-left")
        XCTAssertTrue(shift.waitForExistence(timeout: 5))
        shift.tap()
        waitFor({ (shift.value as? String) == "次の1キー" }, "a tapped Shift latches for the next key")
        element("deck-keys-toggle").tap()
        waitFor({ !self.keysUp }, "the keys go")
        element("deck-keys-toggle").tap()
        waitFor({ self.keysUp }, "the keys come back")
        XCTAssertEqual(shift.value as? String, "オフ", "the latch went with the keys")
    }

    /// Not kept: the deck shown again, or the app started again, has keys.
    func testTheDeckComesBackWithItsKeys() {
        showDeck()
        element("deck-keys-toggle").tap()
        waitFor({ !self.keysUp }, "the keys go")
        element("session-keyboard-button").tap()
        waitFor({ !self.element("laptop-deck").exists }, "the keyboard button hides the deck")
        element("session-keyboard-button").tap()
        waitFor({ self.element("laptop-deck").exists }, "and brings it back")
        XCTAssertTrue(keysUp, "with its keys")

        element("deck-keys-toggle").tap()
        waitFor({ !self.keysUp }, "the keys go")
        app.terminate()
        app.launch()
        connect()
        if !element("laptop-deck").exists { showDeck() }
        XCTAssertTrue(element("laptop-key-a").waitForExistence(timeout: 5), "a new launch has the keys")
    }

    /// The strip stays for the toggle when its shortcuts are turned off.
    func testTheToggleStaysWithoutShortcuts() {
        menu("session-edit-shortcuts")
        let toggle = element("shortcut-deck-strip-toggle")
        // Below the list, which the editor builds only when scrolled to.
        for _ in 0..<6 where !(toggle.exists && toggle.isHittable) {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(toggle.isHittable, "the editor offers the strip toggle\n\(app.debugDescription)")
        if (toggle.value as? String) == "1" { toggle.switches.firstMatch.tap() }
        app.buttons["BackButton"].firstMatch.exists
            ? app.buttons["BackButton"].firstMatch.tap()
            : app.navigationBars["ショートカット"].buttons.element(boundBy: 0).tap()
        element("session-menu-close").tap()
        showDeck()
        XCTAssertTrue(element("deck-keys-toggle").waitForExistence(timeout: 5))
        XCTAssertFalse(element("deck-shortcut-Ctrl+Alt+Delete").exists, "no shortcuts on the strip")
        element("deck-keys-toggle").tap()
        waitFor({ !self.keysUp }, "the toggle still works")
        snapshot("toggle without shortcuts")
    }

    /// Square keys on a phone held upright, the pad below them reaching the
    /// screen's foot, and only the pad changing with the deck's height.
    func testUprightKeysAreSquareAndOnlyThePadResizes() {
        showDeck()
        let key = element("laptop-key-a")
        XCTAssertTrue(key.waitForExistence(timeout: 5))
        XCTAssertEqual(key.frame.width, key.frame.height, accuracy: 1.5, "square keys")
        XCTAssertTrue(padUp)
        let window = app.windows.firstMatch.frame
        let deck = element("laptop-deck").frame
        XCTAssertEqual(deck.maxY, window.maxY, accuracy: 1, "the deck reaches the screen's foot")
        let button = element("laptop-button-left").frame
        XCTAssertGreaterThan(button.maxY, window.maxY - 10, "no room left for the home indicator")
        let keyFrame = key.frame
        let padHeight = element("laptop-trackpad").frame.height

        let handle = element("laptop-deck-resize-handle")
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -4)))
        waitFor({ self.element("laptop-trackpad").frame.height > padHeight + 50 }, "a taller deck, a taller pad")
        XCTAssertEqual(key.frame.size, keyFrame.size, "the keys keep their size")
        snapshot("taller deck")
    }

    /// On its side the phone has no room for a pad beside square keys, at
    /// any height the deck can be dragged to: the keys shrink to fit, the pad
    /// goes and the desktop takes its part. Put away, the keys give the pad
    /// back.
    func testOnItsSideThePhonesPadGoesAndTheDesktopIsTheTrackpad() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "a phone's proportions")
        showDeck()
        // A foldable turned on its side changes display in the Simulator
        // (the hinge reads closed): not a phone held sideways.
        try XCTSkipIf(!workspaceState.contains("hinge=unavailable"), "a foldable: \(workspaceState)")
        XCUIDevice.shared.orientation = .landscapeLeft
        waitFor({ self.workspaceState.contains("deckPad=false") }, "no pad on a short deck: \(self.workspaceState)")
        let key = element("laptop-key-a")
        XCTAssertTrue(key.exists)
        XCTAssertEqual(key.frame.width, key.frame.height, accuracy: 1.5, "still square keys")
        XCTAssertFalse(padUp && element("laptop-trackpad").isHittable)
        let space = element("laptop-key-space").frame
        let deck = element("laptop-deck").frame
        XCTAssertGreaterThan(space.minX - deck.minX, 40, "the keyboard narrower than the deck, in the middle")
        snapshot("landscape keys only")

        dragHandle(to: 0.02)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(workspaceState.contains("deckPad=false"), "even the tallest deck: \(workspaceState)")
        XCTAssertEqual(key.frame.width, key.frame.height, accuracy: 1.5)
        snapshot("landscape tallest deck")

        element("deck-keys-toggle").tap()
        waitFor({ self.workspaceState.contains("deckPad=true") }, "a pad in the keys' place")
        XCTAssertTrue(element("laptop-trackpad").isHittable)
        XCUIDevice.shared.orientation = .portrait
        waitFor({ self.element("laptop-trackpad").isHittable }, "turned upright, still the pad only")
        XCTAssertFalse(keysUp)
    }

    /// An iPad on its side: at half the height the square keys leave no room
    /// for the pad; at three quarters they do.
    func testOnItsSideAnIPadsPadComesWithATallerDeck() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "an iPad's proportions")
        showDeck()
        XCUIDevice.shared.orientation = .landscapeLeft
        waitFor({ self.workspaceState.contains("deckPad=false") }, "half the height: \(self.workspaceState)")
        let key = element("laptop-key-a")
        XCTAssertEqual(key.frame.width, key.frame.height, accuracy: 1.5, "square keys")
        snapshot("iPad landscape half")
        dragHandle(to: 0.02)
        waitFor({ self.workspaceState.contains("deckPad=true") }, "three quarters: \(self.workspaceState)")
        XCTAssertTrue(element("laptop-trackpad").isHittable)
        XCTAssertEqual(key.frame.width, key.frame.height, accuracy: 1.5)
        let esc = element("laptop-key-esc").frame
        XCTAssertLessThan(esc.minX - element("laptop-deck").frame.minX, 20, "the keys span the deck")
        snapshot("iPad landscape tall")
    }

    /// Split at the sides on an iPad on its side: each half square-keyed,
    /// the pad between, and one whole pad when the keys are put away.
    func testSplitHalvesKeepTheirShape() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "split needs a wide screen")
        setSplit(true)
        showDeck()
        XCUIDevice.shared.orientation = .landscapeLeft
        let key = element("laptop-key-a")
        waitFor({ key.exists && abs(key.frame.width - key.frame.height) < 1.5 }, "square keys in the halves")
        waitFor({ self.workspaceState.contains("deckPad=true") }, "the pad between: \(self.workspaceState)")
        snapshot("split")
        element("deck-keys-toggle").tap()
        waitFor({ !self.keysUp }, "the keys go")
        XCTAssertEqual(element("laptop-trackpad").frame.width, element("laptop-deck").frame.width - 12, accuracy: 1,
                       "one pad across the deck")
        snapshot("split pad only")
        element("deck-keys-toggle").tap()
        setSplit(false)
    }

    /// The switch itself, at the row's trailing end: a tap in the middle of
    /// the row lands on its label and does nothing.
    private func setSplit(_ on: Bool) {
        element("session-menu-button").tap()
        XCTAssertTrue(element("session-menu").waitForExistence(timeout: 5))
        let toggle = element("session-laptop-split-toggle")
        scrollMenu(to: toggle)
        if (toggle.value as? String == "1") != on {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        waitFor({ (toggle.value as? String == "1") == on }, "split \(on)")
        element("session-menu-close").tap()
    }

    /// Floating, the smallest panel still has square keys.
    func testTheSmallestFloatingPanelKeepsSquareKeys() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad, "floating needs an iPad")
        menu("session-laptop-deck-placement")
        app.buttons["フローティング"].firstMatch.tap()
        element("session-menu-close").tap()
        showDeck()
        let grip = element("laptop-deck-size-handle")
        XCTAssertTrue(grip.waitForExistence(timeout: 5))
        grip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.95)))
        let key = element("laptop-key-a")
        waitFor({ key.exists && abs(key.frame.width - key.frame.height) < 1.5 }, "square keys: \(key.frame)")
        snapshot("smallest floating")
        menu("session-laptop-deck-reset")
    }

    private func dragHandle(to y: CGFloat) {
        let handle = element("laptop-deck-resize-handle")
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y)))
    }

    /// Keyboard only means the desktop is the pointer - until the keys are
    /// put away and the deck is a pad.
    func testKeyboardOnlyGivesThePointerBackWhenTheKeysGo() {
        showDeck()
        let arrangement = element("session-laptop-deck-arrangement")
        menu("session-laptop-deck-arrangement")
        app.buttons["キーボードのみ（画面を触って操作）"].firstMatch.tap()
        element("session-menu-close").tap()
        waitFor({ self.workspaceState.contains("deckPad=false") }, "keyboard only: \(workspaceState)")
        element("deck-keys-toggle").tap()
        waitFor({ self.workspaceState.contains("deckPad=true") }, "the deck is a pad: \(workspaceState)")
        XCTAssertTrue(element("laptop-trackpad").isHittable)

        element("session-menu-button").tap()
        scrollMenu(to: arrangement)
        arrangement.tap()
        app.buttons["キーボード / トラックパッド"].firstMatch.tap()
        element("session-menu-close").tap()
    }
}
