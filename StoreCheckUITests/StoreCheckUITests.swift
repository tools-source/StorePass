import XCTest

final class StoreCheckUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testManagerCanCreateStore() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        let managerButton = app.buttons["ui_debug_signin_manager"]
        XCTAssertTrue(managerButton.waitForExistence(timeout: 15))
        managerButton.tap()

        let storeName = app.textFields["store_name_input"]
        XCTAssertTrue(storeName.waitForExistence(timeout: 15))
        storeName.tap()
        storeName.typeText("Nadal")

        let storeAddress = app.textFields["store_address_input"]
        XCTAssertTrue(storeAddress.waitForExistence(timeout: 15))
        storeAddress.tap()
        storeAddress.typeText("NY")
        storeAddress.typeText("\n")

        let latitude = app.textFields["store_lat_input"]
        XCTAssertTrue(latitude.waitForExistence(timeout: 15))
        latitude.tap()
        latitude.typeText("40.959967")
        latitude.typeText("\n")

        let longitude = app.textFields["store_lng_input"]
        XCTAssertTrue(longitude.waitForExistence(timeout: 15))
        longitude.tap()
        longitude.typeText("-73.892763")
        longitude.typeText("\n")

        let createButton = app.buttons["create_store_button"]
        XCTAssertTrue(createButton.exists)
        createButton.tap()

        XCTAssertTrue(app.staticTexts["Nadal"].waitForExistence(timeout: 15))
    }

    func testEmployeeCanSignOutFromSettings() {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        let employeeButton = app.buttons["ui_debug_signin_employee"]
        XCTAssertTrue(employeeButton.waitForExistence(timeout: 15))
        employeeButton.tap()

        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 15))
        settingsTab.tap()

        let signOutButton = app.buttons["settings_sign_out_button"]
        XCTAssertTrue(signOutButton.waitForExistence(timeout: 15))
        signOutButton.tap()

        XCTAssertTrue(app.buttons["ui_debug_signin_employee"].waitForExistence(timeout: 15))
    }
}
