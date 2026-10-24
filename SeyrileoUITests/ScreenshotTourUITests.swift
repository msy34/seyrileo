import XCTest

/// TEMPORARY: screenshot tour for the owner (sample source only). Delete after use.
@MainActor
final class ScreenshotTourUITests: XCTestCase {
    var app: XCUIApplication!
    var index = 0

    func launch(_ extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-SeyrileoFixturePort", "47918",
                                "-SeyrileoResetParental"] + extra
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let sample = app.buttons["Try the sample experience"]
        if sample.waitForExistence(timeout: 8) { sample.tap() }
        _ = app.tabBars.buttons["Live"].firstMatch.waitForExistence(timeout: 15)
    }

    func shot(_ name: String) {
        index += 1
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = String(format: "%02d-%@", index, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func button(_ prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    func wait(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    func tapIf(_ element: XCUIElement, _ timeout: TimeInterval = 8) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        element.tap()
        return true
    }

    func type(_ text: String, into identifier: String) {
        let field = app.secureTextFields[identifier].firstMatch
        if tapIf(field, 5) { field.typeText(text) }
    }

    func openSettingsRow(_ label: String) {
        app.tabBars.buttons["Settings"].firstMatch.tap()
        let row = app.buttons[label].firstMatch
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        _ = tapIf(row, 5)
    }

    func closePlayer() {
        if app.buttons["Close player"].firstMatch.exists { app.buttons["Close player"].firstMatch.tap() }
        wait(1)
    }

    /// Owner feedback 2026-10-17: search in Live/Library, landscape full screen controls,
    /// episodes in the player, swipe down to the mini player.
    func testFeedbackTour() throws {
        continueAfterFailure = true
        launch()
        // A fresh simulator can take a while on first launch.
        let sample = app.buttons["Try the sample experience"]
        if sample.waitForExistence(timeout: 60) { sample.tap() }
        _ = app.tabBars.buttons["Live"].firstMatch.waitForExistence(timeout: 60)
        app.tabBars.buttons["Live"].firstMatch.tap()
        let field = app.searchFields.firstMatch
        if tapIf(field) { field.typeText("pattern") }
        wait(2)
        shot("live-search")
        _ = tapIf(app.buttons["Close"].firstMatch, 3)
        wait(1)

        app.tabBars.buttons["Library"].firstMatch.tap()
        _ = tapIf(app.buttons["Series"].firstMatch)
        wait(3)
        let libraryField = app.searchFields.firstMatch
        if tapIf(libraryField) { libraryField.typeText("dizi") }
        wait(2)
        shot("library-search")
        _ = tapIf(button("Test Dizi"))
        _ = tapIf(button("S1 E1"), 15)
        wait(5)
        shot("player-portrait-episode")
        _ = tapIf(app.buttons["Show episodes"].firstMatch)
        wait(3)
        shot("episodes-sheet")
        _ = tapIf(app.buttons["Close"].firstMatch)
        wait(1)
        XCUIDevice.shared.orientation = .landscapeLeft
        wait(2)
        app.otherElements["player.video"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        wait(1)
        shot("player-landscape-fullscreen")
        XCUIDevice.shared.orientation = .portrait
        wait(2)
        app.otherElements["player.video"].firstMatch.swipeDown(velocity: .fast)
        wait(2)
        shot("swipe-down-mini-player")
    }

    func testTour() throws {
        continueAfterFailure = true
        launch()

        _ = tapIf(app.tabBars.buttons["Your Space"].firstMatch)
        wait(3)
        shot("your-space")
        app.swipeUp()
        wait(1)
        shot("your-space-lower")

        _ = tapIf(app.tabBars.buttons["Live"].firstMatch)
        _ = button("Fixture · Pattern Lab").waitForExistence(timeout: 20)
        wait(1)
        shot("live-categories")
        _ = tapIf(button("Fixture · Pattern Lab"))
        wait(2)
        shot("live-channels")
        _ = tapIf(button("Pattern B (HLS)"))
        wait(6)
        shot("player-live")
        if tapIf(app.buttons["Minimize player"].firstMatch, 5) {
            _ = tapIf(app.tabBars.buttons["Library"].firstMatch)
            wait(2)
            shot("mini-player-library")
            app.otherElements["player.mini"].firstMatch.buttons["Close player"].firstMatch.tap()
            wait(1)
        } else { closePlayer() }

        _ = tapIf(app.buttons["Movies"].firstMatch)
        if tapIf(button("Fixture · Films"), 30) {
            wait(1)
            shot("movies")
            if tapIf(button("Test Film MKV")) {
                if tapIf(button("Play")) {
                    wait(3)
                    app.otherElements["player.vlc"].firstMatch.tapIfExists()
                    shot("player-vlc")
                    closePlayer()
                }
                app.navigationBars.buttons.element(boundBy: 0).tapIfExists()
            }
        }

        app.navigationBars.buttons.element(boundBy: 0).tapIfExists()
        _ = tapIf(app.buttons["Series"].firstMatch)
        if tapIf(button("Fixture · Series"), 10) {
            wait(1)
            shot("series-grid")
        }

        _ = tapIf(app.tabBars.buttons["Settings"].firstMatch)
        wait(1)
        shot("settings")
        app.terminate()

        launch(["-SeyrileoFreeTier"])
        _ = tapIf(app.tabBars.buttons["Live"].firstMatch)
        if tapIf(button("Fixture · Pattern Lab"), 20), button("Pattern A (HLS)").waitForExistence(timeout: 10) {
            button("Pattern A (HLS)").press(forDuration: 1.2)
            if tapIf(app.buttons["Rename"].firstMatch, 3) {
                wait(2)
                shot("paywall")
                app.buttons["Close"].firstMatch.tapIfExists()
            }
        }
    }
}
