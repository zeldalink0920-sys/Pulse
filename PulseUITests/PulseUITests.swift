import XCTest

final class PulseUITests: XCTestCase {
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testNavigationAndPersistence() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-reset"]
        app.launch()
        let start = app.buttons["开始感受你的节奏"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        capture("01-Startup", app: app)
        if !start.isHittable { app.swipeUp() }
        start.tap()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 5))
        capture("02-Home", app: app)
        app.tabBars.buttons["Chats"].tap()
        XCTAssertTrue(app.staticTexts["Claude"].waitForExistence(timeout: 5))
        capture("03-Chats", app: app)
        app.tabBars.buttons["Diary"].tap()
        app.buttons["写日记"].tap()
        let editor = app.textViews["diary.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("A quiet moment today.")
        app.buttons["diary.save"].tap()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["A quiet moment today."].waitForExistence(timeout: 5))
        capture("04-Diary", app: app)
        app.tabBars.buttons["Between Us"].tap()
        XCTAssertTrue(app.buttons["Type"].waitForExistence(timeout: 5))
        capture("05-BetweenUs", app: app)
        app.buttons["Letter"].tap()
        app.buttons["Type"].tap()
        let letter = app.textViews.firstMatch
        XCTAssertTrue(letter.waitForExistence(timeout: 5))
        letter.tap()
        letter.typeText("Always close, never far.")
        app.buttons["完成"].tap()
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Diary"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Diary"].tap()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["A quiet moment today."].waitForExistence(timeout: 5))
        app.tabBars.buttons["Between Us"].tap()
        app.buttons["Letter"].tap()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Always close, never far."].waitForExistence(timeout: 5))
    }
}