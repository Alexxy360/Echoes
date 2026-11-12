import XCTest

@MainActor
final class EchoesUITests: XCTestCase {
    private func application(onboarding: Bool = false, largeText: Bool = false, failSend: Bool = false)
        -> XCUIApplication
    {
        let app = XCUIApplication()
        app.launchEnvironment["ECHOES_DEMO_MODE"] = "1"
        if onboarding { app.launchEnvironment["ECHOES_DEMO_ONBOARDING"] = "1" }
        if failSend { app.launchEnvironment["ECHOES_DEMO_FAIL_SEND"] = "1" }
        if largeText {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        }
        app.launch()
        return app
    }

    func testOnboardingEntersPrivatelyAndSettingsOpen() {
        let app = application(onboarding: true)
        let enter = app.buttons["onboarding.enter"]
        XCTAssertTrue(enter.waitForExistence(timeout: 10))
        enter.tap()
        XCTAssertTrue(app.staticTexts["Twój profil jest ukryty."].waitForExistence(timeout: 10))
        let visibility = app.switches["Widoczność na mapie"]
        XCTAssertEqual(visibility.value as? String, "0")
        app.buttons["Ustawienia"].tap()
        XCTAssertTrue(app.textFields["Pseudonim"].waitForExistence(timeout: 5))
        let deleteButton = app.buttons["Usuń moje dane i konto"]
        for _ in 0..<4 where !deleteButton.exists { app.swipeUp() }
        XCTAssertTrue(deleteButton.exists)
        attach(app, name: "settings")
    }

    func testChatSendsDraftAndKeepsNewMessageVisible() {
        let app = application()
        let chat = app.buttons["Czat w okolicy"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        chat.tap()
        let draft = app.descendants(matching: .any).matching(identifier: "chat.draft").firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        draft.tap()
        draft.typeText("Wiadomość demonstracyjna")
        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.isEnabled)
        send.tap()
        XCTAssertTrue(app.staticTexts["Wiadomość demonstracyjna"].waitForExistence(timeout: 5))
        XCTAssertNotEqual(draft.value as? String, "Wiadomość demonstracyjna")
        attach(app, name: "chat")
    }

    func testLargeTextKeepsPrimaryNavigationUsable() {
        let app = application(largeText: true)
        XCTAssertTrue(app.buttons["Czat w okolicy"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Czat w okolicy"].isHittable)
        XCTAssertTrue(app.buttons["Ustawienia"].isHittable)
        let controls = app.otherElements["map.controls"]
        XCTAssertTrue(controls.exists)
        XCTAssertLessThan(controls.frame.height, app.windows.firstMatch.frame.height * 0.45)
        attach(app, name: "map-large-text")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSendErrorKeepsDraftAndShowsFeedbackInsideChat() {
        let app = application(failSend: true)
        XCTAssertTrue(app.buttons["Czat w okolicy"].waitForExistence(timeout: 10))
        app.buttons["Czat w okolicy"].tap()
        let draft = app.descendants(matching: .any).matching(identifier: "chat.draft").firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        draft.tap()
        draft.typeText("Zachowaj szkic po błędzie")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(
            app.staticTexts["Usługa jest chwilowo niedostępna. Spróbuj ponownie później."].waitForExistence(
                timeout: 5))
        XCTAssertEqual(draft.value as? String, "Zachowaj szkic po błędzie")
        XCTAssertTrue(app.buttons["chat.send"].isEnabled)
        attach(app, name: "chat-send-error")
    }
}
