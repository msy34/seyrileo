import XCTest

/// Lifecycle and resource measurements (sample source only, no real provider). Numbers from a
/// simulator are not device numbers; run on a device for those:
///   xcodebuild test -project Seyrileo.xcodeproj -scheme Seyrileo \
///     -only-testing:SeyrileoUITests/LifecycleMeasurementTests -destination 'platform=iOS,id=<UDID>'
@MainActor
final class LifecycleMeasurementTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-SeyrileoTestCatalog", "-SeyrileoFixturePort", "47917", "-SeyrileoResetParental"]
    }

    var session: XCUIElement { app.otherElements["player.session"] }

    func openSample(_ channel: String) {
        app.launch()
        let sample = app.buttons["Try the sample experience"]
        if sample.waitForExistence(timeout: 8) { sample.tap() }
        app.tabBars.buttons["Live"].firstMatch.tap()
        let category = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", channel.hasPrefix("MP2") ? "Fixture · Diagnostics Lab" : "Fixture · Pattern Lab")).firstMatch
        XCTAssertTrue(category.waitForExistence(timeout: 20))
        category.tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", channel)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        waitFor("playing", timeout: 30)
    }

    func waitFor(_ state: String, timeout: TimeInterval) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", state + "|"), object: session)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: timeout), .completed, "state: \(session.value ?? "nil")")
    }

    func idle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func testColdLaunchTime() throws {
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            app.launch()
            app.terminate()
        }
    }

    /// 20 s of live HLS in the built-in player (AVPlayer).
    func testLivePlaybackResourcesAVPlayer() throws {
        openSample("Pattern A (HLS)")
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        measure(metrics: [XCTMemoryMetric(application: app), XCTCPUMetric(application: app)], options: options) {
            idle(20)
        }
        waitFor("playing", timeout: 5)
    }

    /// 20 s of live HLS with MP2 audio, which plays in VLC (software decoding, frame output).
    func testLivePlaybackResourcesVLC() throws {
        openSample("MP2 audio (HLS)")
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        measure(metrics: [XCTMemoryMetric(application: app), XCTCPUMetric(application: app)], options: options) {
            idle(20)
        }
    }

    /// Background during playback and return: the same session is kept (background audio).
    func testBackgroundAndReturnKeepsSession() throws {
        openSample("Pattern A (HLS)")
        let before = (session.value as? String)?.split(separator: "|").last
        XCUIDevice.shared.press(.home)
        idle(8)
        app.activate()
        XCTAssertTrue(session.waitForExistence(timeout: 10), "player gone after background:\n\(app.debugDescription)")
        waitFor("playing", timeout: 20)
        XCTAssertEqual((session.value as? String)?.split(separator: "|").last, before, "stream was reopened")
    }
}
