import XCTest

/// Movies, series, resume and continue watching against the on-device sample source only.
@MainActor
final class LibraryUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-SeyrileoTestCatalog", "-SeyrileoFixturePort", "47917"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let sample = app.buttons["Try the sample experience"]
        if sample.waitForExistence(timeout: 8) { sample.tap() }
        XCTAssertTrue(app.tabBars.buttons["Library"].firstMatch.waitForExistence(timeout: 15))
    }

    var session: XCUIElement { app.otherElements["player.session"] }

    func button(startingWith prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    func waitForState(_ state: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", state + "|"), object: session)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed,
                       "expected \(state), got \(session.value ?? "nil")", file: file, line: line)
    }

    func open(_ kind: String, category: String, title: String) {
        app.tabBars.buttons["Library"].firstMatch.tap()
        app.buttons[kind].firstMatch.tap()
        let row = button(startingWith: category)
        XCTAssertTrue(row.waitForExistence(timeout: 30), "library did not load:\n\(app.debugDescription)")
        row.tap()
        let item = button(startingWith: title)
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.tap()
    }

    func testMovieResumeAndContinueWatching() throws {
        open("Movies", category: "Fixture · Films", title: "Test Film A")
        let play = button(startingWith: "Play")
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        waitForState("playing")
        // Watch past the 30 s "really started" threshold; there is no faster signal to wait on.
        RunLoop.current.run(until: Date().addingTimeInterval(36))
        app.buttons["Close player"].tap()

        let resume = button(startingWith: "Resume from")
        XCTAssertTrue(resume.waitForExistence(timeout: 10), "no resume offered:\n\(app.debugDescription)")
        XCTAssertTrue(button(startingWith: "Play from the beginning").exists)

        app.tabBars.buttons["Your Space"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Continue watching"].waitForExistence(timeout: 10))
        let entry = button(startingWith: "Test Film A")
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        waitForState("playing")
        app.buttons["Close player"].tap()
    }

    func testSeriesEpisodeNavigation() throws {
        open("Series", category: "Fixture · Series", title: "Test Dizi")
        let first = button(startingWith: "S1 E1")
        XCTAssertTrue(first.waitForExistence(timeout: 15), "episodes did not load:\n\(app.debugDescription)")
        first.tap()
        waitForState("playing")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'S1 E1'")).firstMatch.exists)
        let before = (session.value as? String)?.split(separator: "|").last
        app.buttons["Next episode"].tap()
        waitForState("playing")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'S1 E2'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertNotEqual((session.value as? String)?.split(separator: "|").last, before, "episode switch must replace the player")
        app.buttons["Close player"].tap()
    }

    func testLibrarySearchFindsSeriesAcrossCategories() throws {
        app.tabBars.buttons["Library"].firstMatch.tap()
        app.buttons["Series"].firstMatch.tap()
        XCTAssertTrue(button(startingWith: "Fixture · Series").waitForExistence(timeout: 30), "library did not load")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no search field in Library:\n\(app.debugDescription)")
        field.tap()
        field.typeText("dizi")
        let result = button(startingWith: "Test Dizi")
        XCTAssertTrue(result.waitForExistence(timeout: 10), "series not found by search:\n\(app.debugDescription)")
        result.tap()
        XCTAssertTrue(button(startingWith: "S1 E1").waitForExistence(timeout: 15))
    }

    /// Landscape is full screen: previous/next and "Show episodes" are on the video, and an
    /// episode picked from the list plays in the same player screen.
    func testLandscapeFullScreenKeepsEpisodeControls() throws {
        open("Series", category: "Fixture · Series", title: "Test Dizi")
        let first = button(startingWith: "S1 E1")
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        first.tap()
        waitForState("playing")

        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let next = app.buttons["Next episode"]
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == false"), object: app.buttons["Close player"])
        XCTAssertEqual(XCTWaiter().wait(for: [closed], timeout: 5), .completed, "header still shown in landscape")
        if !next.isHittable { app.otherElements["player.video"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap() }
        XCTAssertTrue(next.waitForExistence(timeout: 5) && next.isHittable, "no next episode in full screen:\n\(app.debugDescription)")
        next.tap()
        waitForState("playing")

        // Back in portrait the header returns, showing the episode the overlay switched to.
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'S1 E2'")).firstMatch.waitForExistence(timeout: 5))
        let episodes = app.buttons["Show episodes"].firstMatch
        XCTAssertTrue(episodes.waitForExistence(timeout: 5), "no Show episodes button:\n\(app.debugDescription)")
        episodes.tap()
        let episodeOne = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'S1 E1'")).firstMatch
        XCTAssertTrue(episodeOne.waitForExistence(timeout: 10), "episode list empty:\n\(app.debugDescription)")
        episodeOne.tap()
        waitForState("playing")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'S1 E1'")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["Close player"].tap()
    }

    func testMKVPlaysInVLCAndUnknownFormatIsExplained() throws {
        // MKV starts directly in the alternate engine (VLC) and plays.
        open("Movies", category: "Fixture · Films", title: "Test Film MKV")
        button(startingWith: "Play").tap()
        waitForState("playing")
        XCTAssertTrue((session.value as? String)?.contains("|VLC:") == true, "MKV did not use VLC: \(session.value ?? "nil")")
        app.buttons["Close player"].tap()

        app.navigationBars.buttons.firstMatch.tap()
        let unknown = button(startingWith: "Test Film (no container)")
        XCTAssertTrue(unknown.waitForExistence(timeout: 5))
        unknown.tap()
        button(startingWith: "Play").tap()
        XCTAssertTrue(app.alerts["This title can't be opened"].waitForExistence(timeout: 10))
        app.alerts.buttons["OK"].tap()
    }

    /// Closing a VLC title right after it starts: VLC's video thread may still deliver a picture
    /// after the engine is gone (VLCKit stops asynchronously). This crashed the app once.
    func testClosingVLCRightAfterStartDoesNotCrash() throws {
        open("Movies", category: "Fixture · Films", title: "Test Film MKV")
        for round in 1...6 {
            let play = button(startingWith: "Play")
            XCTAssertTrue(play.waitForExistence(timeout: 10), "round \(round): no play button")
            play.tap()
            waitForState("playing")
            app.buttons["Close player"].tap()
            XCTAssertTrue(session.waitForNonExistence(timeout: 5), "round \(round): player did not close")
            XCTAssertEqual(app.state, .runningForeground, "round \(round): app is not running")
        }
    }
}

@MainActor
final class LivePlaybackFallbackUITests: XCTestCase {
    /// Live HLS with MPEG-1 Layer II audio (like the owner's provider): AVPlayer fails with
    /// 'fmt?', the session falls back once to VLC and plays.
    func testLiveMP2AudioFallsBackToVLC() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-SeyrileoTestCatalog", "-SeyrileoFixturePort", "47917"]
        app.launch()
        let sample = app.buttons["Try the sample experience"]
        if sample.waitForExistence(timeout: 8) { sample.tap() }
        app.tabBars.buttons["Live"].firstMatch.tap()
        let category = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Fixture · Diagnostics Lab")).firstMatch
        XCTAssertTrue(category.waitForExistence(timeout: 20))
        category.tap()
        let channel = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "MP2 audio (HLS)")).firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 10))
        channel.tap()
        let session = app.otherElements["player.session"]
        let playingInVLC = NSPredicate(format: "value BEGINSWITH 'playing|VLC:'")
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: playingInVLC, object: session)], timeout: 30)
        XCTAssertEqual(result, .completed, "got \(session.value ?? "nil") log: \(app.otherElements["player.log"].value ?? "nil")")
        app.buttons["Close player"].tap()
    }
}
