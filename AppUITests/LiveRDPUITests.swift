import XCTest

/// Connects the real app to a real Windows host, then holds the session open
/// so it can be driven and inspected from outside the test - by hand, or by
/// a script tapping the Simulator and reading the host over SSH.
///
/// Skipped unless the host is given. Nothing about the host is in the
/// repository; pass it to `xcodebuild test` as
///
///     TEST_RUNNER_MREMOTE_LIVE_HOST=192.0.2.10
///     TEST_RUNNER_MREMOTE_LIVE_USER=someone
///     TEST_RUNNER_MREMOTE_LIVE_PASSWORD=...
///     TEST_RUNNER_MREMOTE_LIVE_HOLD=600      # seconds to keep the session
///     TEST_RUNNER_MREMOTE_LIVE_COMMANDS=/path/commands.txt   # optional
///
/// With a command file, lines appended to it while the session is held are
/// carried out in order, and `<file>.done` gets one line per finished
/// command. Elements are named by accessibility identifier; fractions are
/// of the element's size.
///
///     tap <id>                         tap
///     twotap <id>                      two-finger tap
///     hold <id> <seconds>              press and hold
///     tapat <id> <fx> <fy>             tap at a point
///     drag <id> <fx1> <fy1> <fx2> <fy2> [holdSeconds]
///     keys <id> <id> ...               tap each in turn
///     sleep <seconds>
///     value <id>                       report the element's value
///     swipeup <id>                     swipe up on an element
///     button <label>                   tap the button with this label
///
/// The password is typed into the credential prompt and not saved.
final class LiveRDPUITests: XCTestCase {
    private var app: XCUIApplication!
    private let environment = ProcessInfo.processInfo.environment
    private let profileName = "Live RDP"

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func testConnectAndHold() throws {
        guard let host = environment["MREMOTE_LIVE_HOST"],
              let user = environment["MREMOTE_LIVE_USER"],
              let password = environment["MREMOTE_LIVE_PASSWORD"] else {
            throw XCTSkip("MREMOTE_LIVE_HOST, _USER and _PASSWORD are not set")
        }
        let hold = TimeInterval(environment["MREMOTE_LIVE_HOLD"] ?? "") ?? 300
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()

        let row = element("profile-row-\(profileName)")
        if !row.waitForExistence(timeout: 5) {
            addProfile(host: host, user: user)
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the profile is listed")
        row.tap()
        XCTAssertTrue(element("session-workspace").waitForExistence(timeout: 15))

        answerChallenges(password: password)
        XCTAssertTrue(
            element("session-status").waitForNonExistence(timeout: 60),
            "the desktop replaces the status text\n\(app.debugDescription)"
        )
        // Held for whoever is driving: the session stays up until this ends.
        let commandPath = environment["MREMOTE_LIVE_COMMANDS"]
        var performed = 0
        let deadline = Date().addingTimeInterval(hold)
        while Date() < deadline {
            // Prompts can come back, after a reconnect for instance.
            answerChallenges(password: password, wait: 0)
            if let commandPath {
                let lines = ((try? String(contentsOfFile: commandPath, encoding: .utf8)) ?? "")
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map(String.init)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                while performed < lines.count {
                    let result = perform(lines[performed])
                    performed += 1
                    append("\(performed) \(result) \(lines[performed - 1])\n", to: commandPath + ".done")
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    private func perform(_ line: String) -> String {
        let words = line.split(separator: " ").map(String.init)
        guard let verb = words.first else { return "empty" }
        let arguments = Array(words.dropFirst())
        func target(_ index: Int = 0) -> XCUIElement? {
            guard arguments.count > index else { return nil }
            let found = element(arguments[index])
            return found.exists ? found : nil
        }
        func number(_ index: Int) -> CGFloat {
            arguments.count > index ? CGFloat(Double(arguments[index]) ?? 0) : 0
        }
        switch verb {
        case "tap":
            guard let target = target() else { return "missing" }
            target.tap()
        case "twotap":
            guard let target = target() else { return "missing" }
            target.twoFingerTap()
        case "hold":
            guard let target = target() else { return "missing" }
            target.press(forDuration: TimeInterval(number(1)))
        case "tapat":
            guard let target = target() else { return "missing" }
            target.coordinate(withNormalizedOffset: CGVector(dx: number(1), dy: number(2))).tap()
        case "drag":
            guard let target = target() else { return "missing" }
            let from = target.coordinate(withNormalizedOffset: CGVector(dx: number(1), dy: number(2)))
            let to = target.coordinate(withNormalizedOffset: CGVector(dx: number(3), dy: number(4)))
            from.press(forDuration: max(TimeInterval(number(5)), 0.05), thenDragTo: to)
        case "keys":
            for identifier in arguments {
                let key = element(identifier)
                guard key.exists else { return "missing \(identifier)" }
                key.tap()
            }
        case "swipeup":
            guard let target = target() else { return "missing" }
            target.swipeUp()
        case "button":
            let button = app.buttons[arguments.joined(separator: " ")].firstMatch
            guard button.waitForExistence(timeout: 3) else { return "missing" }
            button.tap()
        case "value":
            guard let target = target() else { return "missing" }
            return "value=\(target.value.map { "\($0)" } ?? "nil") label=\(target.label)"
        case "sleep":
            Thread.sleep(forTimeInterval: TimeInterval(number(0)))
        default:
            return "unknown"
        }
        return "ok"
    }

    private func append(_ text: String, to path: String) {
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
        }
    }

    private func addProfile(host: String, user: String) {
        let add = element("add-profile-button").exists
            ? element("add-profile-button") : element("empty-add-profile-button")
        add.tap()
        let name = element("profile-name-field")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        app.typeText(profileName)
        element("profile-host-field").tap()
        app.typeText(host)
        let username = app.textFields["ユーザー名"].firstMatch
        username.tap()
        app.typeText(user)
        element("profile-save-button").tap()
    }

    /// Certificate review and credentials, in whichever order the host asks.
    private func answerChallenges(password: String, wait: TimeInterval = 30) {
        let deadline = Date().addingTimeInterval(wait)
        repeat {
            if element("certificate-trust-always").exists {
                element("certificate-trust-always").tap()
            } else if element("challenge-password").exists {
                element("challenge-password").tap()
                app.typeText(password)
                element("challenge-connect").tap()
            } else if wait > 0, !element("session-status").exists {
                return
            }
            Thread.sleep(forTimeInterval: 1)
        } while Date() < deadline
    }
}
