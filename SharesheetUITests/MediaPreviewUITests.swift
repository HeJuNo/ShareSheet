import XCTest

/// Repro for the media viewer: after a swipe the pages must stay centred.
@MainActor
final class MediaPreviewUITests: XCTestCase {
    func testSwipingMediaPages() throws {
        let app = try openDetail()

        let thumb = app.buttons["Media 1 of 3, image"].firstMatch
        XCTAssertTrue(thumb.waitForExistence(timeout: 10), app.debugDescription)
        thumb.tap()

        sleep(2)
        shot("page-1")
        XCTAssertCentered(app.images["Media 1 of 3"].firstMatch, in: app)

        app.swipeLeft()
        sleep(1)
        shot("page-2")
        XCTAssertCentered(app.images["Media 2 of 3"].firstMatch, in: app)

        app.swipeLeft()
        sleep(1)
        shot("page-3")
        XCTAssertCentered(app.images["Media 3 of 3"].firstMatch, in: app)

        app.swipeRight()
        sleep(1)
        shot("page-2-back")
        XCTAssertCentered(app.images["Media 2 of 3"].firstMatch, in: app)
    }

    func testOpensAtTappedMedia() throws {
        let app = try openDetail()

        let thumb = app.buttons["Media 3 of 3, image"].firstMatch
        XCTAssertTrue(thumb.waitForExistence(timeout: 10), app.debugDescription)
        thumb.tap()

        sleep(2)
        shot("opened-at-page-3")
        XCTAssertCentered(app.images["Media 3 of 3"].firstMatch, in: app)
    }

    /// Local probe: the mixed sample (image, video, HEIC, WebP, audio) shows which thumbnails Quick Look cannot make.
    func testMixedMediaThumbnails() throws {
        let app = XCUIApplication()
        app.launch()
        let unsorted = app.staticTexts["Unsorted"].firstMatch
        XCTAssertTrue(unsorted.waitForExistence(timeout: 15), app.debugDescription)
        unsorted.tap()
        let item = app.staticTexts["Mixed Media"].firstMatch
        guard item.waitForExistence(timeout: 10) else { throw XCTSkip("Seed Mixed Media first.") }
        item.tap()

        let first = app.buttons["Media 1 of 5, image"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10), app.debugDescription)
        sleep(5)
        shot("mixed-strip-1")
        first.swipeLeft()
        sleep(2)
        shot("mixed-strip-2")
        app.buttons["Media 3 of 5, image"].firstMatch.swipeLeft()
        sleep(2)
        shot("mixed-strip-3")
    }

    /// The sample post seeded into the simulator library; skipped where the seed is not present.
    private func openDetail() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()

        let unsorted = app.staticTexts["Unsorted"].firstMatch
        XCTAssertTrue(unsorted.waitForExistence(timeout: 15), app.debugDescription)
        unsorted.tap()

        let item = app.staticTexts["Media Test"].firstMatch
        guard item.waitForExistence(timeout: 10) else {
            throw XCTSkip("Seed SimulatorLibrary/Unsorted/Media Test.md with three media files first.")
        }
        item.tap()
        return app
    }

    /// The page must keep the full screen width and start at its left edge after every swipe.
    private func XCTAssertCentered(_ image: XCUIElement, in app: XCUIApplication,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let screen = app.windows.firstMatch.frame
        print("FRAME:", image.frame, "screen:", screen)
        XCTAssertTrue(image.exists, file: file, line: line)
        XCTAssertEqual(image.frame.minX, 0, accuracy: 1, file: file, line: line)
        XCTAssertEqual(image.frame.width, screen.width, accuracy: 1, file: file, line: line)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
