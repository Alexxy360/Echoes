import XCTest

@MainActor final class GatewaySettingsUITests: XCTestCase {
    func testPhotoSettingsRemainReachableWithLargestAccessibilityText() {
        let app = XCUIApplication()
        app.launchEnvironment["ECHOES_GATEWAY_COMMUNITY_UI_PREVIEW"] = "avatar-owner-existing-approved"
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["Ustawienia"].waitForExistence(timeout: 15))
        app.buttons["Ustawienia"].tap()
        let avatar = app.buttons["settings.avatar"]
        for _ in 0..<9 where !avatar.exists || !avatar.isHittable { app.swipeUp() }
        XCTAssertTrue(avatar.isHittable)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "settings-photo-largest-accessibility-text"
        attachment.lifetime = .keepAlways
        add(attachment)
        avatar.tap()
        XCTAssertTrue(app.navigationBars["Twoje zdjęcie"].waitForExistence(timeout: 10))
    }

    func testNicknameKeyboardCanBeDismissedWithLargestAccessibilityText() {
        let app = XCUIApplication()
        app.launchEnvironment["ECHOES_GATEWAY_COMMUNITY_UI_PREVIEW"] = "avatar-owner-existing-approved"
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["Ustawienia"].waitForExistence(timeout: 15))
        app.buttons["Ustawienia"].tap()
        let name = app.textFields["settings.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let original = name.value as? String
        name.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        let hide = app.buttons["settings.keyboard.hide"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5) && hide.isHittable)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "settings-nickname-keyboard-largest-accessibility-text"
        attachment.lifetime = .keepAlways
        add(attachment)
        hide.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))
        XCTAssertEqual(name.value as? String, original)
        XCTAssertTrue(app.buttons["Zapisz pseudonim"].exists)
    }
}
