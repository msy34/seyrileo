import XCTest

/// Aliases, hiding and collections against the on-device sample source only. Each test
/// restores what it changed, so it can run repeatedly on the same simulator.
@MainActor
final class OrganizationUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-SeyrileoTestCatalog", "-SeyrileoFixturePort", "47917"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        let sample = app.buttons["Try the sample experience"]
        if sample.waitForExistence(timeout: 8) { sample.tap() }
        XCTAssertTrue(app.tabBars.buttons["Live"].firstMatch.waitForExistence(timeout: 15))
    }

    func button(startingWith prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    func openPatternLab() {
        app.tabBars.buttons["Live"].firstMatch.tap()
        let category = button(startingWith: "Fixture · Pattern Lab")
        XCTAssertTrue(category.waitForExistence(timeout: 20), "sample categories did not load:\n\(app.debugDescription)")
        category.tap()
        XCTAssertTrue(button(startingWith: "Pattern B (HLS)").waitForExistence(timeout: 10))
    }

    func menu(on row: XCUIElement, choose action: String) {
        row.press(forDuration: 1.2)
        let item = app.buttons[action].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "context menu item \(action) missing:\n\(app.debugDescription)")
        item.tap()
    }

    func replaceText(in field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let current = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        field.typeText(text)
    }

    func testAliasIsShownSearchableAndReversible() throws {
        openPatternLab()
        menu(on: button(startingWith: "Pattern A (HLS)"), choose: "Rename")
        replaceText(in: app.textFields["name.field"], with: "Desen Kanalı")
        app.navigationBars.buttons["Save"].tap()

        let renamed = button(startingWith: "Desen Kanalı")
        XCTAssertTrue(renamed.waitForExistence(timeout: 5), "alias not shown:\n\(app.debugDescription)")
        // The provider's name stays visible under the alias.
        XCTAssertTrue(renamed.label.contains("Pattern A (HLS)"), renamed.label)

        // The alias is searchable, ignoring Turkish letters and case.
        // The search field is collapsed into the navigation bar until the list is pulled down.
        app.cells.firstMatch.swipeDown()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("kanali")
        XCTAssertTrue(button(startingWith: "Desen Kanalı").waitForExistence(timeout: 5))
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8))

        menu(on: button(startingWith: "Desen Kanalı"), choose: "Rename")
        let reset = app.buttons["Use the provider's name"].firstMatch
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        reset.tap()
        XCTAssertTrue(button(startingWith: "Pattern A (HLS)").waitForExistence(timeout: 5))
        XCTAssertFalse(button(startingWith: "Desen Kanalı").exists)
    }

    func testHiddenChannelCanBeRestored() throws {
        openPatternLab()
        menu(on: button(startingWith: "Pattern B (HLS)"), choose: "Hide channel")
        XCTAssertTrue(button(startingWith: "Pattern B (HLS)").waitForNonExistence(timeout: 5))

        app.navigationBars.buttons.element(boundBy: 0).tap()  // back to categories
        app.buttons["Organize"].firstMatch.tap()
        app.buttons["Hidden channels and categories"].firstMatch.tap()
        // The row reads "<channel>, Show" and is one button.
        let show = button(startingWith: "Pattern B (HLS)")
        XCTAssertTrue(show.waitForExistence(timeout: 5), "hidden list empty:\n\(app.debugDescription)")
        show.tap()
        XCTAssertTrue(app.staticTexts["Nothing hidden"].waitForExistence(timeout: 5))

        app.navigationBars.buttons.element(boundBy: 0).tap()
        button(startingWith: "Fixture · Pattern Lab").tap()
        XCTAssertTrue(button(startingWith: "Pattern B (HLS)").waitForExistence(timeout: 5))
    }

    func testCollectionHoldsAChannelAndCanBeDeleted() throws {
        let name = "Akşam \(Int.random(in: 100...999))"
        openPatternLab()
        menu(on: button(startingWith: "Pattern B (HLS)"), choose: "Add to collection")
        let field = app.textFields["New collection"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(name)
        app.buttons["Create"].firstMatch.tap()
        XCTAssertTrue(button(startingWith: name).waitForExistence(timeout: 5))
        XCTAssertTrue(button(startingWith: name).isSelected, "new collection should contain the channel")
        // Not the keyboard's "done" key: the sheet's own button.
        app.navigationBars["Add to collection"].buttons["Done"].tap()

        app.tabBars.buttons["Your Space"].firstMatch.tap()
        let collection = button(startingWith: name)
        XCTAssertTrue(collection.waitForExistence(timeout: 10), "collection missing in Your Space:\n\(app.debugDescription)")
        collection.tap()
        XCTAssertTrue(button(startingWith: "Pattern B (HLS)").waitForExistence(timeout: 5))

        let more = app.buttons["collection.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), "collection menu missing:\n\(app.debugDescription)")
        more.tap()
        app.buttons["Delete collection"].firstMatch.tap()
        // Confirmation dialog repeats the action.
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Delete collection'")).element(boundBy: 0)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(button(startingWith: name).waitForNonExistence(timeout: 5))
    }
}
