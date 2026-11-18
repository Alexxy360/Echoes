import XCTest

/// Profile/UI acceptance with the actual store and native community adapter; providers remain synthetic.
@MainActor final class GatewayProfileUITests: XCTestCase {
    private func application(_ mode: String, large: Bool = false, legacy: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ECHOES_GATEWAY_COMMUNITY_UI_PREVIEW"] = mode
        if legacy { app.launchArguments += ["-userName", "LegacyAnonymous", "-privacyAcceptedV2", "YES"] }
        if large {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        }
        app.launch()
        return app
    }
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func reveal(_ app: XCUIApplication, _ item: XCUIElement, up: Bool = true) {
        for _ in 0..<8 where !item.isHittable {
            if up { app.swipeUp() } else { app.swipeDown() }
        }
        XCTAssertTrue(item.isHittable)
    }
    private func settings(_ app: XCUIApplication) -> XCUIElement {
        XCTAssertTrue(app.buttons["Ustawienia"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Ustawienia"].isEnabled)
        app.buttons["Ustawienia"].tap()
        let field = element(app, "settings.name")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        return field
    }
    private func editName(_ app: XCUIApplication, _ field: XCUIElement) -> String {
        reveal(app, field, up: false)
        field.tap()
        field.typeText("Zmiana")
        let result = field.value as? String ?? ""
        XCTAssertTrue(result.contains("Zmiana"))
        let hide = app.buttons["settings.keyboard.hide"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        hide.tap()
        return result
    }
    private func closeAndReopen(_ app: XCUIApplication) {
        app.buttons["community.preview.actions"].tap()
        app.buttons["Zamknij sesję testową"].tap()
        XCTAssertTrue(element(app, "community.preview.closed").waitForExistence(timeout: 5))
        app.buttons["Otwórz nową sesję testową"].tap()
    }
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testNewPrivateNameDoesNotImportLegacyAndSurvivesNewPresentation() {
        let app = application("profile-empty", legacy: true)
        let field = element(app, "onboarding.name")
        XCTAssertTrue(element(app, "profile.loaded").waitForExistence(timeout: 10))
        reveal(app, field)
        XCTAssertNotEqual(field.value as? String, "LegacyAnonymous")
        XCTAssertTrue(["", "Twój pseudonim"].contains(field.value as? String ?? ""))
        XCTAssertFalse(app.buttons["onboarding.enter"].isEnabled)
        field.tap()
        field.typeText("NowyProfil")
        app.buttons["onboarding.keyboard.hide"].tap()
        let enter = app.buttons["onboarding.enter"]
        reveal(app, enter)
        enter.tap()
        let name = settings(app)
        XCTAssertEqual(name.value as? String, "NowyProfil")
        XCTAssertTrue(element(app, "profile.loaded").label.contains("NowyProfil"))
        app.buttons["Gotowe"].tap()
        closeAndReopen(app)
        XCTAssertTrue(element(app, "profile.loaded").waitForExistence(timeout: 10))
        let restored = element(app, "onboarding.name")
        reveal(app, restored)
        XCTAssertEqual(restored.value as? String, "NowyProfil")
        attach(app, "profile-private-restored")
    }
    func testOfflineReadRequiresExplicitRefreshAndNeverFallsBackToLegacyName() {
        let app = application("profile-offline", legacy: true)
        let error = element(app, "profile.error")
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["onboarding.enter"].isEnabled)
        XCTAssertFalse(app.buttons["Ustawienia"].isEnabled)
        let refresh = app.buttons["profile.refresh"]
        reveal(app, refresh)
        refresh.tap()
        XCTAssertTrue(error.waitForNonExistence(timeout: 5))
        let field = element(app, "onboarding.name")
        reveal(app, field)
        XCTAssertEqual(field.value as? String, "Zapisany pseudonim")
        let enter = app.buttons["onboarding.enter"]
        reveal(app, enter)
        XCTAssertTrue(enter.isEnabled)
        attach(app, "profile-offline-reloaded")
        enter.tap()
        XCTAssertTrue(app.staticTexts["Twój profil jest ukryty."].waitForExistence(timeout: 10))
    }
    func testConflictPreservesDraftAndOnlyExplicitSaveAfterReloadChangesSessionName() {
        let app = application("profile-conflict")
        let field = settings(app)
        let draft = editName(app, field)
        app.buttons["settings.saveName"].tap()
        let error = element(app, "profile.error")
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings.saveName"].isEnabled)
        XCTAssertTrue(element(app, "settings.currentName").label.contains("Gość"))
        XCTAssertEqual(field.value as? String, draft)
        let refresh = app.buttons["profile.refresh"]
        reveal(app, refresh)
        refresh.tap()
        XCTAssertTrue(error.waitForNonExistence(timeout: 5))
        XCTAssertTrue(element(app, "profile.loaded").label.contains("Nazwa z drugiego urządzenia"))
        reveal(app, field, up: false)
        XCTAssertEqual(field.value as? String, draft)
        attach(app, "profile-conflict-reconciled")
        let save = app.buttons["settings.saveName"]
        reveal(app, save)
        save.tap()
        XCTAssertTrue(app.staticTexts["Pseudonim został zapisany w iCloud."].waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "settings.currentName").label.contains(draft))
    }
    func testUnknownWriteRequiresReloadWithoutChangingActiveNameOrLosingDraft() {
        let app = application("profile-unknown")
        let field = settings(app)
        let draft = editName(app, field)
        app.buttons["settings.saveName"].tap()
        let error = element(app, "profile.error")
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "settings.currentName").label.contains("Gość"))
        XCTAssertFalse(app.buttons["settings.saveName"].isEnabled)
        XCTAssertEqual(field.value as? String, draft)
        let refresh = app.buttons["profile.refresh"]
        reveal(app, refresh)
        refresh.tap()
        XCTAssertTrue(error.waitForNonExistence(timeout: 5))
        XCTAssertTrue(element(app, "profile.loaded").label.contains(draft))
        XCTAssertTrue(element(app, "settings.currentName").label.contains("Gość"))
        reveal(app, field, up: false)
        XCTAssertEqual(field.value as? String, draft)
        attach(app, "profile-unknown-reloaded")
        let save = app.buttons["settings.saveName"]
        reveal(app, save)
        save.tap()
        XCTAssertTrue(app.staticTexts["Pseudonim został zapisany w iCloud."].waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "settings.currentName").label.contains(draft))
    }
    func testDelayedReadFromPreviousAccountCannotPopulateNewOnboarding() {
        let app = application("profile-delayed")
        XCTAssertTrue(element(app, "profile.loading").waitForExistence(timeout: 10))
        app.buttons["community.preview.actions"].tap()
        app.buttons["Zmień konto testowe"].tap()
        XCTAssertTrue(element(app, "profile.loaded").waitForExistence(timeout: 10))
        let field = element(app, "onboarding.name")
        reveal(app, field)
        XCTAssertEqual(field.value as? String, "Pseudonim konta B")
        app.buttons["community.preview.actions"].tap()
        app.buttons["Zakończ opóźniony odczyt"].tap()
        let stale = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "Zapisany pseudonim"), object: field)
        stale.isInverted = true
        wait(for: [stale], timeout: 1)
        XCTAssertEqual(field.value as? String, "Pseudonim konta B")
        attach(app, "profile-new-account-after-late-read")
    }
    func testLargeTextKeepsRestoredNameAndConsentActionAccessible() {
        let app = application("profile-onboarding", large: true)
        XCTAssertTrue(element(app, "profile.loaded").waitForExistence(timeout: 10))
        let field = element(app, "onboarding.name")
        reveal(app, field)
        XCTAssertEqual(field.value as? String, "Zapisany pseudonim")
        let enter = app.buttons["onboarding.enter"]
        reveal(app, enter)
        XCTAssertLessThanOrEqual(enter.frame.maxX, app.windows.firstMatch.frame.maxX + 1)
        XCTAssertGreaterThanOrEqual(enter.frame.minX, 0)
        attach(app, "profile-onboarding-large-text")
        enter.tap()
        XCTAssertTrue(app.staticTexts["Twój profil jest ukryty."].waitForExistence(timeout: 10))
    }

    func testLargestTextCanDismissOnboardingKeyboardWithoutChangingPrivateName() {
        let app = application("profile-onboarding", large: true)
        XCTAssertTrue(element(app, "profile.loaded").waitForExistence(timeout: 10))
        let field = element(app, "onboarding.name")
        reveal(app, field)
        let original = field.value as? String
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        let hide = app.buttons["onboarding.keyboard.hide"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5) && hide.isHittable)
        attach(app, "profile-onboarding-keyboard-largest-text")
        hide.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, original)
        XCTAssertTrue(element(app, "onboarding.enter").exists)
    }
}
