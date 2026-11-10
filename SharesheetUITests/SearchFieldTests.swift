import XCTest

final class SearchFieldTests: XCTestCase {
    /// The search field must stay after the first typed letter (the home list swaps to the results then).
    func testSearchFieldStaysAfterTheFirstLetter() {
        let app = XCUIApplication()
        app.launch()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("a")
        XCTAssertEqual(field.value as? String, "a")
        XCTAssertTrue(app.searchFields.firstMatch.exists)
        field.typeText("b")  // keeps accepting letters
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "ab")
    }
}
