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
        app.launchArguments = ["--ui-testing-reset", "--ui-testing-restaurants"]
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
        app.launchArguments = ["--ui-testing-restaurants"]
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

    func testRestaurantSettingsPersistence() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-reset", "--ui-testing-restaurants"]
        app.launch()
        let start = app.buttons["开始感受你的节奏"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        if !start.isHittable { app.swipeUp() }
        start.tap()
        app.tabBars.buttons["设置"].tap()
        app.buttons["restaurant.add"].tap()
        let name = app.textFields["restaurant.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Restaurant One")
        let key = app.secureTextFields["restaurant.key"]
        key.tap(); key.typeText("ui-test-placeholder-one")
        app.buttons["restaurant.save"].tap()
        XCTAssertTrue(app.staticTexts["Restaurant One"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["restaurant.add"].tap()
        let secondName = app.textFields["restaurant.name"]
        XCTAssertTrue(secondName.waitForExistence(timeout: 5))
        secondName.tap(); secondName.typeText("Restaurant Two")
        let address = app.textFields["restaurant.address"]
        app.buttons["restaurant.clear-address"].tap()
        address.tap()
        address.typeText("https://order.lydialink.es/r/restaurant-2/api/v1/status")
        app.secureTextFields["restaurant.key"].tap()
        app.secureTextFields["restaurant.key"].typeText("ui-test-placeholder-two")
        app.buttons["restaurant.save"].tap()
        XCTAssertTrue(app.staticTexts["Restaurant Two"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--ui-testing-restaurants"]
        app.launch()
        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.staticTexts["Restaurant One"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Restaurant Two"].exists)
        XCTAssertTrue(app.staticTexts["https://order.lydialink.es/r/restaurant-2"].exists, app.debugDescription)
        capture("06-RestaurantSettings", app: app)
        app.staticTexts["Restaurant Two"].tap()
        XCTAssertTrue(app.buttons["restaurant.connect"].waitForExistence(timeout: 5))
        app.buttons["编辑地址与密钥"].tap()
        XCTAssertTrue(app.textFields["restaurant.name"].waitForExistence(timeout: 5))
        // A blank edit retains this restaurant's existing Keychain credential.
        app.buttons["restaurant.save"].tap()
        XCTAssertTrue(app.buttons["restaurant.connect"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["Home"].tap()
        for _ in 0..<4 {
            if app.buttons["restaurant.page.0"].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["restaurant.page.0"].exists)
        XCTAssertTrue(app.buttons["restaurant.page.1"].exists)
        XCTAssertTrue(app.buttons["restaurant.page.2"].exists)
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "restaurant.home.")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        capture("07-RestaurantHome", app: app)
        card.tap()
        XCTAssertTrue(app.staticTexts["近 7 天用餐人数"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["restaurant.history.chart"].exists)
        XCTAssertTrue(app.staticTexts["2026-10-10"].exists)
        capture("08-RestaurantHistory", app: app)
        app.buttons["完成"].tap()
        app.tabBars.buttons["设置"].tap()
        app.staticTexts["Restaurant Two"].tap()
        app.buttons["删除餐馆"].tap()
        app.sheets.buttons["删除餐馆"].tap()
        XCTAssertTrue(app.staticTexts["Restaurant One"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Restaurant Two"].exists)
    }

}
