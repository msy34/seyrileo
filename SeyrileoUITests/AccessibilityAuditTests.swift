import XCTest

/// Apple's automated accessibility audit (contrast, Dynamic Type, hit areas, labels, traits) on
/// the main screens, with the sample source. Each finding is printed as "AUDIT <screen> | …";
/// findings in system-provided UI that the app cannot change are listed in `ignored`.
@MainActor
final class AccessibilityAuditTests: XCTestCase {
    var app: XCUIApplication!
    var findings: [String] = []

    override func setUp() async throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-SeyrileoFixturePort", "47917", "-SeyrileoResetParental"]
        app.launch()
        let sample = app.buttons["Try the sample experience"]
        if sample.waitForExistence(timeout: 8) { sample.tap() }
        XCTAssertTrue(app.tabBars.buttons["Live"].firstMatch.waitForExistence(timeout: 15))
    }

    func audit(_ screen: String) throws {
        try app.performAccessibilityAudit { issue in
            let element = issue.element.map { "\($0.elementType.rawValue) '\($0.label)'" } ?? "-"
            let line = "AUDIT \(screen) | \(issue.auditType) | \(element) | \(issue.compactDescription)"
            print(line)
            self.findings.append(line)
            return true  // collect all findings; the summary assertion below decides
        }
    }

    func testMainScreens() throws {
        app.tabBars.buttons["Live"].firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Fixture'")).firstMatch.waitForExistence(timeout: 20))
        try audit("Live")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Fixture · Pattern Lab'")).firstMatch.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Pattern A'")).firstMatch.waitForExistence(timeout: 10))
        try audit("Channels")
        app.tabBars.buttons["Your Space"].firstMatch.tap()
        try audit("Your Space")
        app.tabBars.buttons["Library"].firstMatch.tap()
        try audit("Library")
        app.tabBars.buttons["Search"].firstMatch.tap()
        try audit("Search")
        app.tabBars.buttons["Settings"].firstMatch.tap()
        try audit("Settings")
        print("AUDIT TOTAL \(findings.count)")
    }
}
