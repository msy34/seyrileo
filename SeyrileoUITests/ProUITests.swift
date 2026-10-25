import XCTest

/// Free tier and the Pro paywall (sample source only; `-SeyrileoFreeTier` turns off the DEBUG
/// unlock). The price comes from Config/Seyrileo.storekit when the scheme's StoreKit
/// configuration is active.
@MainActor
final class ProUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-SeyrileoTestCatalog", "-SeyrileoFixturePort", "47917",
                                "-SeyrileoResetParental", "-SeyrileoFreeTier"]
        app.launch()
        let sample = app.buttons["Try the sample experience"]
        if sample.waitForExistence(timeout: 8) { sample.tap() }
        XCTAssertTrue(app.tabBars.buttons["Your Space"].firstMatch.waitForExistence(timeout: 15))
    }

    func button(startingWith prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    var paywall: XCUIElement { app.descendants(matching: .any)["pro.paywall"].firstMatch }

    func closePaywall() {
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(paywall.waitForNonExistence(timeout: 5))
    }

    /// Version 1 ships without Pro (`ProStore.isOffered = false`): even with `-SeyrileoFreeTier`
    /// nothing asks for Pro and Settings shows no Pro section.
    func testVersionOneIsFreeWithoutPaywall() throws {
        app.tabBars.buttons["Live"].firstMatch.tap()
        let category = button(startingWith: "Fixture · Pattern Lab")
        XCTAssertTrue(category.waitForExistence(timeout: 20))
        category.tap()
        let channel = button(startingWith: "Pattern A (HLS)")
        XCTAssertTrue(channel.waitForExistence(timeout: 10))
        channel.press(forDuration: 1.2)
        app.buttons["Rename"].firstMatch.tap()
        XCTAssertTrue(app.textFields["name.field"].firstMatch.waitForExistence(timeout: 5), "no rename sheet:\n\(app.debugDescription)")
        XCTAssertFalse(paywall.exists)
        app.navigationBars.buttons["Cancel"].firstMatch.tap()

        app.tabBars.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        for _ in 0..<3 { app.swipeUp() }
        XCTAssertFalse(app.buttons["Get Seyrileo Pro"].exists)
        XCTAssertFalse(app.staticTexts["Seyrileo Pro (development build)"].exists)
    }

    func testRenamingIsProAndTheFirstCollectionIsFree() throws {
        throw XCTSkip("Pro is not offered in version 1 (ProStore.isOffered = false).")
        // Advanced organization opens the paywall in the free tier.
        app.tabBars.buttons["Live"].firstMatch.tap()
        let category = button(startingWith: "Fixture · Pattern Lab")
        XCTAssertTrue(category.waitForExistence(timeout: 20))
        category.tap()
        let channel = button(startingWith: "Pattern A (HLS)")
        XCTAssertTrue(channel.waitForExistence(timeout: 10))
        channel.press(forDuration: 1.2)
        app.buttons["Rename"].firstMatch.tap()
        XCTAssertTrue(paywall.waitForExistence(timeout: 5), "paywall missing:\n\(app.debugDescription)")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "paywall"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("PAYWALL price shown: \(button(startingWith: "Unlock for").exists)")
        closePaywall()

        // One collection is free; the second one needs Pro. Clean up afterwards.
        app.tabBars.buttons["Your Space"].firstMatch.tap()
        let name = "Free \(Int.random(in: 100...999))"
        let newCollection = app.buttons["New collection"].firstMatch
        for _ in 0..<4 where !newCollection.isHittable { app.swipeUp() }
        newCollection.tap()
        let field = app.textFields["name.field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no name sheet:\n\(app.debugDescription)")
        field.typeText(name)
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(button(startingWith: name).waitForExistence(timeout: 5))
        newCollection.tap()
        XCTAssertTrue(paywall.waitForExistence(timeout: 5), "second collection did not ask for Pro")
        closePaywall()

        button(startingWith: name).swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(button(startingWith: name).waitForNonExistence(timeout: 5))
    }
}
