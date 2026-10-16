import XCTest

/// Parental PIN against the on-device sample source only. Starts from no PIN
/// (`-SeyrileoResetParental`) and removes the PIN it creates.
@MainActor
final class ParentalUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-SeyrileoFixturePort", "47917", "-SeyrileoResetParental"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let sample = app.buttons["Try the sample experience"]
        if sample.waitForExistence(timeout: 8) { sample.tap() }
        XCTAssertTrue(app.tabBars.buttons["Settings"].firstMatch.waitForExistence(timeout: 15))
    }

    func button(startingWith prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    func type(_ text: String, into identifier: String) {
        let field = app.secureTextFields[identifier].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "\(identifier) missing:\n\(app.debugDescription)")
        field.tap()
        field.typeText(text)
    }

    func openSettingsRow(_ label: String) {
        app.tabBars.buttons["Settings"].firstMatch.tap()
        let row = app.buttons[label].firstMatch
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "\(label) missing:\n\(app.debugDescription)")
        row.tap()
    }

    func testLockedCategoryNeedsPINOnEveryRoute() throws {
        // 1. Create a PIN.
        openSettingsRow("Create PIN")
        type("2580", into: "parental.new")
        type("2580", into: "parental.confirm")
        app.navigationBars.buttons["Save"].tap()

        // 2. Lock the sample category (needs no PIN right now: the session is unlocked).
        app.tabBars.buttons["Live"].firstMatch.tap()
        let category = button(startingWith: "Fixture · Pattern Lab")
        XCTAssertTrue(category.waitForExistence(timeout: 20))
        category.swipeLeft()
        // A failed earlier run may have left the lock in place.
        if app.buttons["Lock"].firstMatch.waitForExistence(timeout: 3) { app.buttons["Lock"].firstMatch.tap() } else { category.tap() }

        // 3. Lock the session; the category name is hidden now.
        openSettingsRow("Lock now")
        app.tabBars.buttons["Live"].firstMatch.tap()
        let locked = button(startingWith: "Locked category")
        XCTAssertTrue(locked.waitForExistence(timeout: 5), "category not masked:\n\(app.debugDescription)")
        XCTAssertFalse(button(startingWith: "Fixture · Pattern Lab").exists)

        // 4. Search does not reveal or play its channels.
        app.tabBars.buttons["Search"].firstMatch.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("pattern")
        XCTAssertTrue(button(startingWith: "Locked channel").waitForExistence(timeout: 5), "search leaked:\n\(app.debugDescription)")
        XCTAssertFalse(button(startingWith: "Pattern A (HLS)").exists)
        button(startingWith: "Locked channel").tap()
        // The PIN prompt appears instead of the player; a wrong PIN is refused.
        type("1111", into: "parental.pin")
        app.navigationBars.buttons["Unlock"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Wrong PIN'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["player.session"].exists)
        app.navigationBars.buttons["Cancel"].tap()
        XCTAssertFalse(app.otherElements["player.session"].waitForExistence(timeout: 2), "played without PIN")

        // 5. Opening the category asks for the PIN; the right one unlocks it.
        app.tabBars.buttons["Live"].firstMatch.tap()
        button(startingWith: "Locked category").tap()
        app.buttons["Unlock"].firstMatch.tap()
        type("2580", into: "parental.pin")
        app.navigationBars.buttons["Unlock"].tap()
        XCTAssertTrue(button(startingWith: "Pattern A (HLS)").waitForExistence(timeout: 10), "not unlocked:\n\(app.debugDescription)")

        // 6. Clean up: unlock the category, then remove the PIN.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let unlockedCategory = button(startingWith: "Fixture · Pattern Lab")
        XCTAssertTrue(unlockedCategory.waitForExistence(timeout: 5))
        unlockedCategory.swipeLeft()
        app.buttons["Remove lock"].firstMatch.tap()
        openSettingsRow("Remove PIN")
        type("2580", into: "parental.current")
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Create PIN"].waitForExistence(timeout: 5))
    }
}
