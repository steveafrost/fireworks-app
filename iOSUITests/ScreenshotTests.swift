import XCTest

/// Captures the screens the App Store listing needs, from the app running rather than
/// from a mock-up, and checks the one rule the demo has to keep.
///
/// Two launch arguments drive it, both DEBUG-only (a shipped build has neither path):
///
/// * `--render-ui-sample` — the sample figures with the label off, which is what a
///   configured account looks like. This is what the store listing and the README
///   should show.
/// * `--demo` — the same figures labelled, which is what a reviewer or a first-time
///   buyer meets when they tap "See a demo".
///
/// The PNGs are written to the test runner's temporary directory (findable on the host
/// under the simulator's device folder) and attached to the result bundle, so they
/// survive either way.
final class ScreenshotTests: XCTestCase {
    private var outputDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fireworks-shots", isDirectory: true)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    /// Wait for the reading to be on screen before capturing: a screenshot taken during
    /// the first frame is a screenshot of an empty screen.
    private func waitForReading(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Today"].waitForExistence(timeout: 30),
                      "the reading never arrived — nothing to capture")
    }

    private func capture(_ name: String) {
        let screen = XCUIScreen.main.screenshot()
        let url = outputDirectory.appendingPathComponent("\(name).png")
        try? screen.pngRepresentation.write(to: url)
        let attachment = XCTAttachment(screenshot: screen)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("FIREWORKS-SHOT \(url.path)")
    }

    /// The listing's screens: what the app looks like with an account behind it.
    ///
    /// Built from genuinely different states rather than from a swipe per picture. The
    /// whole app fits on the largest iPhone in one screen — swiping up four times
    /// produced four byte-identical PNGs, which is how that was discovered — so the set
    /// is the overview, the settings it lets you change, and the first screen a buyer
    /// meets.
    func testCaptureStoreScreens() throws {
        let app = launch(["--render-ui-sample"])
        waitForReading(app)
        capture("01-overview")

        // The toolbar gear is an SF Symbol with no title, so it is looked up by the
        // symbol's own name.
        let gear = app.buttons["gearshape"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "the settings button is missing")
        gear.tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 10),
                      "the settings sheet did not open")
        capture("02-settings")
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
    }

    /// The screen a buyer meets before they have a key: what the app is, and the two
    /// ways forward.
    func testCaptureSetupCard() throws {
        let app = launch([])
        XCTAssertTrue(app.staticTexts["Your key is the whole setup"].waitForExistence(timeout: 30),
                      "an unconfigured app shows the setup card")
        XCTAssertTrue(app.buttons["see-demo"].exists, "the way to look before deciding")
        capture("03-setup")
    }

    /// The demo's one promise, as an assertion: sample figures are never passed off as
    /// the account's, and there is always a way back out of them.
    func testTheDemoIsLabelled() throws {
        let app = launch(["--demo"])
        waitForReading(app)
        XCTAssertTrue(app.staticTexts["DEMO"].waitForExistence(timeout: 10),
                      "the demo must announce itself before its figures are read")
        XCTAssertTrue(app.staticTexts["Sample numbers — not your account"].exists,
                      "the demo has to say whose numbers these are not")
        XCTAssertTrue(app.buttons["Exit demo"].exists, "the demo needs a way out")
        capture("demo-labelled")
    }
}
