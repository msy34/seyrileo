import XCTest

/// App Store screenshots from the fictional showcase catalogue (`-SeyrileoShowcase`).
/// Not part of the regular suite: run it on purpose, e.g.
/// `TEST_RUNNER_SHOT_LANGS="en tr" xcodebuild test -only-testing:SeyrileoUITests/AppStoreScreenshotsUITests …`.
/// Screens are reached by position and by catalogue names (provider data, not translated), so the
/// same steps work in every app language. Images are XCTest attachments named `<lang>-<nn>-<name>`.
@MainActor
final class AppStoreScreenshotsUITests: XCTestCase {
    var app: XCUIApplication!

    var languages: [String] {
        (ProcessInfo.processInfo.environment["SHOT_LANGS"] ?? "en").split(separator: " ").map(String.init)
    }

    func launch(language: String) {
        app = XCUIApplication()
        app.launchArguments += ["-SeyrileoShowcase", "-SeyrileoFixturePort", ProcessInfo.processInfo.environment["SHOT_PORT"] ?? "47930", "-SeyrileoResetParental",
                                "-appLanguage", language, "-AppleLanguages", "(\(language))"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let sample = app.buttons["welcome.sample"].firstMatch
        if sample.waitForExistence(timeout: 30) { sample.tap() }
        _ = app.buttons["welcome.sample"].waitForNonExistence(timeout: 60)
        wait(3)
    }

    /// iPhone: the tab bar. iPad: the top tab bar, whose buttons carry their SF Symbol names.
    func tab(_ index: Int) -> XCUIElement {
        if app.tabBars.firstMatch.exists { return app.tabBars.buttons.element(boundBy: index) }
        let symbols = ["square.grid.2x2", "dot.radiowaves.left.and.right", "film.stack", "magnifyingglass", "gearshape"]
        return app.buttons[symbols[index]].firstMatch
    }

    func button(_ prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    func wait(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    func shot(_ language: String, _ number: Int, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = String(format: "%@-%02d-%@", language, number, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func back() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        wait(1)
    }

    /// Favorites, a recently watched channel and two titles in progress, so "Your Space" is not empty.
    func prepareLibrary() {
        launch(language: "en")
        tab(1).tap()
        XCTAssertTrue(button("Documentaries").waitForExistence(timeout: 30))
        button("Documentaries").tap()
        for name in ["Wild North", "Ocean Atlas", "Star Lab"] {
            let row = button(name)
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.swipeLeft()
            app.buttons["Add to favorites"].firstMatch.tap()
            wait(1)
        }
        button("Mountain Rails").tap()
        wait(8)
        app.buttons["Close player"].firstMatch.tapIfExists()
        back()

        tab(2).tap()
        app.segmentedControls.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(button("New this week").waitForExistence(timeout: 30))
        button("New this week").tap()
        XCTAssertTrue(button("The Saffron Lighthouse").waitForExistence(timeout: 10))
        button("The Saffron Lighthouse").tap()
        XCTAssertTrue(button("Play").waitForExistence(timeout: 10))
        button("Play").tap()
        wait(50)
        app.buttons["Close player"].firstMatch.tapIfExists()
        back()
        back()

        app.segmentedControls.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(button("Popular series").waitForExistence(timeout: 30))
        button("Popular series").tap()
        XCTAssertTrue(button("Night Shift Diaries").waitForExistence(timeout: 10))
        button("Night Shift Diaries").tap()
        let episode = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Small Hours")).firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 10))
        episode.tap()
        wait(45)
        app.buttons["Close player"].firstMatch.tapIfExists()
        wait(2)
        app.terminate()
    }

    func testAppStoreScreenshots() throws {
        guard ProcessInfo.processInfo.environment["SHOT_LANGS"] != nil else {
            throw XCTSkip("Set TEST_RUNNER_SHOT_LANGS to take App Store screenshots.")
        }
        continueAfterFailure = true
        prepareLibrary()
        for language in languages {
            launch(language: language)
            tab(0).tap()
            wait(4)
            shot(language, 1, "your-space")

            tab(1).tap()
            if app.buttons["live.guide"].firstMatch.waitForExistence(timeout: 20) {
                app.buttons["live.guide"].firstMatch.tap()
                wait(4)
                shot(language, 3, "guide")
                back()
            }
            if button("Documentaries").waitForExistence(timeout: 20) {
                button("Documentaries").tap()
                wait(3)
                shot(language, 2, "live-channels")
                button("Ocean Atlas").tap()
                wait(10)
                shot(language, 4, "player")
                app.buttons["Close player"].firstMatch.tapIfExists()
                wait(1)
                back()
            }

            tab(2).tap()
            app.segmentedControls.buttons.element(boundBy: 0).tap()
            if button("New this week").waitForExistence(timeout: 20) {
                button("New this week").tap()
                wait(4)
                shot(language, 5, "movies")
                button("Tuesday the Cat").tapIfExists()
                wait(3)
                shot(language, 6, "movie-detail")
                back()
                back()
            }
            app.segmentedControls.buttons.element(boundBy: 1).tap()
            if button("Popular series").waitForExistence(timeout: 20) {
                button("Popular series").tap()
                wait(4)
                shot(language, 8, "series")
                button("Moonlit Market").tapIfExists()
                wait(4)
                shot(language, 7, "series-detail")
                back()
                back()
            }
            app.terminate()
        }
    }
}

