import XCTest

/// Exercises the actual native adapter/domain with synthetic authorization/API and an in-memory journal.
@MainActor final class GatewayCommunityUITests: XCTestCase {
    private func application(_ mode: String = "happy", large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ECHOES_GATEWAY_COMMUNITY_UI_PREVIEW"] = mode
        if large {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        }
        app.launch()
        XCTAssertTrue(element(app, "community.preview.banner").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Czat w okolicy"].waitForExistence(timeout: 10))
        return app
    }
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func chat(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["Czat w okolicy"].tap()
        let draft = element(app, "chat.draft")
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        return draft
    }
    @discardableResult
    private func edit(_ app: XCUIApplication, _ draft: XCUIElement, _ text: String) -> String {
        draft.tap()
        draft.typeText(text)
        let edited = draft.value as? String ?? ""
        XCTAssertTrue(edited.contains(text))
        let hide = app.buttons["chat.keyboard.hide"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        hide.tap()
        return edited
    }
    private func reveal(_ app: XCUIApplication, _ item: XCUIElement) {
        for _ in 0..<7 where !item.isHittable { app.swipeUp() }
        XCTAssertTrue(item.isHittable)
    }
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testNativeChatSendsAndSettingsRouteToAppleDeletionFlow() {
        let app = application()
        let draft = chat(app)
        edit(app, draft, "Native adapter message")
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.staticTexts["Native adapter message"].waitForExistence(timeout: 5))
        app.buttons["Zamknij"].tap()
        app.buttons["Ustawienia"].tap()
        let account = app.buttons["settings.native.account"]
        reveal(app, account)
        XCTAssertTrue(element(app, "settings.native.privacy").exists)
        XCTAssertFalse(app.buttons["Usuń moje dane i konto"].exists)
        attach(app, "community-native-settings")
        account.tap()
        XCTAssertTrue(app.navigationBars["Podgląd usuwania"].waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "gateway.deletion.previewBanner").exists)
        XCTAssertFalse(app.buttons["Usuń moje dane"].exists)
        attach(app, "community-account-route")
    }
    func testPendingRetryKeepsEditedNewDraft() {
        let app = application("pending")
        let draft = chat(app)
        XCTAssertTrue(element(app, "chat.pending.text").waitForExistence(timeout: 5))
        let edited = edit(app, draft, "Next independent draft")
        XCTAssertFalse(app.buttons["chat.send"].isEnabled)
        let retry = app.buttons["chat.pending.retry"]
        reveal(app, retry)
        attach(app, "community-pending-edited")
        retry.tap()
        XCTAssertTrue(retry.waitForNonExistence(timeout: 5))
        XCTAssertEqual(draft.value as? String, edited)
        XCTAssertTrue(app.buttons["chat.send"].isEnabled)
        attach(app, "community-pending-retried")
    }
    func testLocalForgetNeedsConfirmationAndPreservesEditedDraft() {
        let app = application("pending")
        let draft = chat(app)
        let edited = edit(app, draft, "Keep edited draft")
        let forget = app.buttons["chat.pending.forget"]
        reveal(app, forget)
        forget.tap()
        let dialog = app.alerts.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts[
                "To nie usuwa wiadomości z serwera. Mogła już dotrzeć do innych osób. Nowy szkic pozostanie na urządzeniu."
            ].exists)
        attach(app, "community-local-forget-confirmation")
        app.alerts.buttons["chat.pending.cancel"].firstMatch.tap()
        XCTAssertTrue(forget.exists)
        XCTAssertEqual(draft.value as? String, edited)
        forget.tap()
        app.alerts.buttons["chat.pending.confirm"].firstMatch.tap()
        XCTAssertTrue(forget.waitForNonExistence(timeout: 5))
        XCTAssertEqual(draft.value as? String, edited)
        XCTAssertTrue(app.buttons["chat.send"].isEnabled)
    }
    func testAccountChangeClearsOldDraftAndStartsHidden() {
        let app = application("pending")
        let draft = chat(app)
        edit(app, draft, "Previous account private draft")
        app.buttons["Zamknij"].tap()
        app.buttons["community.preview.actions"].tap()
        app.buttons["Zmień konto testowe"].tap()
        XCTAssertTrue(app.staticTexts["Twój profil jest ukryty."].waitForExistence(timeout: 10))
        let nextDraft = chat(app)
        XCTAssertFalse(element(app, "chat.pending.text").exists)
        XCTAssertFalse((nextDraft.value as? String ?? "").contains("Previous account private draft"))
        XCTAssertFalse(app.buttons["chat.send"].isEnabled)
        attach(app, "community-new-account-empty")
    }
    func testBackgroundClosesChatAndErasesPresentationBeforeReturning() {
        let app = application()
        let draft = chat(app)
        edit(app, draft, "Private before background")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(element(app, "community.preview.closed").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "chat.draft").exists)
        app.buttons["Otwórz nową sesję testową"].tap()
        XCTAssertTrue(app.buttons["Czat w okolicy"].waitForExistence(timeout: 10))
        let nextDraft = chat(app)
        XCTAssertNotEqual(nextDraft.value as? String, "Private before background")
        attach(app, "community-background-new-session")
    }
    func testLargeTextKeepsRecoveryActionsWithinScrollableContent() {
        let app = application("pending", large: true)
        let draft = chat(app)
        let retry = app.buttons["chat.pending.retry"]
        reveal(app, retry)
        XCTAssertLessThanOrEqual(retry.frame.maxX, app.windows.firstMatch.frame.maxX + 1)
        XCTAssertGreaterThanOrEqual(retry.frame.minX, 0)
        let banner = element(app, "community.preview.sheetBanner")
        XCTAssertTrue(banner.exists)
        XCTAssertLessThanOrEqual(draft.frame.maxY, banner.frame.minY + 1)
        attach(app, "community-pending-large-text")
    }

    func testLargestTextCanDismissChatKeyboardWithoutSendingOrLosingDraft() {
        let app = application("happy", large: true)
        let draft = chat(app)
        draft.tap()
        let text = "Pierwszy wiersz\nDrugi wiersz"
        draft.typeText(text)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        let hide = app.buttons["chat.keyboard.hide"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5) && hide.isHittable)
        XCTAssertEqual(draft.value as? String, text)
        attach(app, "community-chat-keyboard-largest-text")
        hide.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))
        XCTAssertEqual(draft.value as? String, text)
        XCTAssertFalse(app.staticTexts[text].exists)
        XCTAssertTrue(app.buttons["chat.send"].isEnabled)
    }
}
