import XCTest

/// Fullscreen / player-session regression tests. Uses only the on-device sample source
/// (no real provider, no credentials). Run on a dedicated simulator:
///   xcodebuild test -project Seyrileo.xcodeproj -scheme Seyrileo -only-testing:SeyrileoUITests \
///     -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
@MainActor
final class PlayerPresentationUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-SeyrileoTestCatalog", "-SeyrileoFixturePort", "47917"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
    }

    /// The player exposes "state|player-identity" (no URLs or credentials) for tests.
    var session: XCUIElement { app.otherElements["player.session"] }

    func openSampleChannel(_ name: String = "Pattern A (HLS)") {
        let sample = app.buttons["Try the sample experience"]
        if sample.waitForExistence(timeout: 10) { sample.tap() }
        app.tabBars.buttons["Live"].firstMatch.tapIfExists()
        let category = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Fixture · Pattern Lab")).firstMatch
        XCTAssertTrue(category.waitForExistence(timeout: 20), "sample categories did not load:\n\(app.debugDescription)")
        category.tap()
        let channel = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 10), "channel not found:\n\(app.debugDescription)")
        channel.tap()
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        waitForState("playing")
    }

    func waitForState(_ state: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "value BEGINSWITH %@", state + "|")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: session)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "expected \(state), got \(session.value ?? "nil")", file: file, line: line)
    }

    var sessionValue: String { (session.value as? String) ?? "" }

    func fullScreenButton() -> XCUIElement {
        // AVKit's own inline control; its label is localized by the system.
        let predicate = NSPredicate(format: "label CONTAINS[c] 'full screen' OR identifier CONTAINS[c] 'fullscreen'")
        return app.buttons.matching(predicate).firstMatch
    }

    /// Shows AVKit's controls without hitting its centered play/pause button.
    func revealAVKitControls() {
        app.otherElements["player.video"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
    }

    func testEnteringAndLeavingFullScreenKeepsTheSameSession() throws {
        openSampleChannel()
        let before = sessionValue

        revealAVKitControls()
        let enter = fullScreenButton()
        XCTAssertTrue(enter.waitForExistence(timeout: 5), "AVKit full screen control not found. Buttons: \(app.buttons.allElementsBoundByIndex.map(\.label))")
        enter.tap()

        // In native full screen our header (close button) must not cover the video.
        XCTAssertFalse(app.buttons["Close player"].isHittable, "app header is still on top in full screen")

        XCUIDevice.shared.orientation = .landscapeLeft
        sleepRunLoop(2)
        XCUIDevice.shared.orientation = .portrait
        sleepRunLoop(1)

        // Leave full screen with AVKit's own control. Reveal controls with a tap near the top
        // edge: the center of AVKit's full-screen view is its play/pause button.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        let exit = app.buttons.matching(NSPredicate(format: "(label CONTAINS[c] 'exit full screen' OR label CONTAINS[c] 'done' OR label CONTAINS[c] 'close') AND label != 'Close player'")).firstMatch
        if exit.waitForExistence(timeout: 5) { exit.tap() }

        XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 10), "player screen was closed by leaving full screen")
        waitForState("playing")
        XCTAssertEqual(sessionValue.split(separator: "|").last, before.split(separator: "|").last,
                       "a different AVPlayer is in use after full screen (stream was reopened)")
    }

    func testRotationAndChannelSwitchKeepSinglePlayingSession() throws {
        openSampleChannel()
        XCUIDevice.shared.orientation = .landscapeLeft
        sleepRunLoop(2)
        waitForState("playing")
        XCUIDevice.shared.orientation = .portrait
        sleepRunLoop(1)
        app.buttons["Next channel"].tap()
        waitForState("playing")
        XCTAssertTrue(app.staticTexts["Pattern B (HLS)"].exists)
        app.buttons["Close player"].tap()
        XCTAssertFalse(session.waitForExistence(timeout: 2))
    }

    func testMinimizedPlayerKeepsTheSessionWhileBrowsing() throws {
        openSampleChannel()
        let before = sessionValue
        app.buttons["Minimize player"].tap()

        let mini = app.otherElements["player.mini"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 5), "mini player missing:\n\(app.debugDescription)")
        // Browse elsewhere: the mini player stays.
        app.tabBars.buttons["Library"].firstMatch.tap()
        XCTAssertTrue(mini.waitForExistence(timeout: 3))
        app.tabBars.buttons["Your Space"].firstMatch.tap()
        XCTAssertTrue(mini.exists)

        // Back to full screen: same player object, still playing (the stream was not reopened).
        mini.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Pattern A'")).firstMatch.tap()
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        waitForState("playing")
        XCTAssertEqual(sessionValue.split(separator: "|").last, before.split(separator: "|").last)

        // Minimize again and close from the mini player: the session ends.
        app.buttons["Minimize player"].tap()
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        mini.buttons["Close player"].tap()
        XCTAssertTrue(mini.waitForNonExistence(timeout: 5))
    }

    func testLiveTabSearchPlaysAChannel() throws {
        let sample = app.buttons["Try the sample experience"]
        if sample.waitForExistence(timeout: 10) { sample.tap() }
        app.tabBars.buttons["Live"].firstMatch.tapIfExists()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no search field in Live:\n\(app.debugDescription)")
        field.tap()
        field.typeText("pattern b")
        let channel = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Pattern B (HLS)")).firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 10), "channel not found by search:\n\(app.debugDescription)")
        channel.tap()
        waitForState("playing")
        app.buttons["Close player"].tap()
    }

    func testSwipeDownMinimizesToTheMiniPlayer() throws {
        openSampleChannel()
        let before = sessionValue
        app.otherElements["player.video"].firstMatch.swipeDown(velocity: .fast)
        let mini = app.otherElements["player.mini"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 5), "swipe down did not minimize:\n\(app.debugDescription)")
        XCTAssertTrue(app.tabBars.buttons["Live"].firstMatch.isHittable, "tabs are not back")
        mini.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Pattern A'")).firstMatch.tap()
        waitForState("playing")
        XCTAssertEqual(sessionValue.split(separator: "|").last, before.split(separator: "|").last)
        app.buttons["Close player"].tap()
    }

    func testAirPlayRoutePickerIsNativeAndPresent() throws {
        openSampleChannel()
        let picker = app.buttons["AirPlay"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "native route picker missing from the player header")
        XCTAssertTrue(picker.isHittable)
    }

    private func sleepRunLoop(_ seconds: TimeInterval) {
        // Rotation animations have no completion signal in XCUITest.
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}

extension XCUIElement {
    func tapIfExists() {
        if waitForExistence(timeout: 3) { tap() }
    }
}
