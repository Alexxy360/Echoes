import XCTest

/// UI fixtures only: no native Apple sheet, Keychain, CloudKit or HTTP. The banner must stay visible.
@MainActor final class GatewayDeletionUITests: XCTestCase {
    private func application(_ mode: String, largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ECHOES_GATEWAY_DELETION_UI_PREVIEW"] = mode
        if largeText {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        }
        app.launch()
        XCTAssertTrue(element(app, "gateway.deletion.previewBanner").waitForExistence(timeout: 10))
        return app
    }
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func reveal(_ app: XCUIApplication, _ target: XCUIElement) {
        for _ in 0..<7 where !target.isHittable { app.swipeUp() }
        XCTAssertTrue(target.exists)
        XCTAssertTrue(target.isHittable)
    }
    private func revealText(_ app: XCUIApplication, _ target: XCUIElement) {
        func visible() -> Bool {
            guard target.exists else { return false }
            let window = app.windows.firstMatch.frame
            let top = max(window.minY, app.navigationBars.firstMatch.frame.maxY)
            let viewport = CGRect(
                x: window.minX, y: top, width: window.width, height: max(0, window.maxY - top - 20))
            return target.frame.intersection(viewport).height >= min(32, target.frame.height)
        }
        for _ in 0..<7 where !visible() { app.swipeUp() }
        XCTAssertTrue(visible())
    }
    private func attach(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }
    func testPendingDeletionNeedsAnExplicitStepAndShowsManualAppleStateSeparately() {
        let app = application("pending")
        let pending = element(app, "gateway.deletion.pending")
        XCTAssertTrue(pending.waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "gateway.deletion.completed").exists)
        attach(app, "deletion-pending")
        let next = app.buttons["gateway.deletion.continue"]
        reveal(app, next)
        next.tap()
        XCTAssertTrue(element(app, "gateway.deletion.completed").waitForExistence(timeout: 10))
        let manual = element(app, "gateway.deletion.appleManual")
        reveal(app, manual)
        XCTAssertFalse(app.buttons["gateway.deletion.continue"].exists)
        attach(app, "deletion-completed-manual")
    }
    func testRecoveryShowsConfirmationAndNeverClaimsCompletionBeforeNewProof() {
        let app = application("recovery")
        XCTAssertTrue(element(app, "gateway.deletion.needsProof").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "gateway.deletion.completed").exists)
        XCTAssertFalse(app.buttons["gateway.deletion.continue"].exists)
        let recovery = app.buttons["gateway.deletion.recoverSaved"]
        reveal(app, recovery)
        recovery.tap()
        let confirm = app.buttons["Potwierdź przez Apple"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        attach(app, "deletion-recovery-confirmation")
        let cancel = app.buttons["gateway.deletion.cancel"].firstMatch
        XCTAssertTrue(cancel.exists)
        cancel.tap()
        XCTAssertTrue(element(app, "gateway.deletion.needsProof").exists)
        XCTAssertFalse(element(app, "gateway.deletion.completed").exists)
        XCTAssertFalse(element(app, "gateway.deletion.error").exists)
    }
    func testLargeTextCompletedReceiptKeepsItsNoticeReadableAndHasNoContinueAction() {
        let app = application("completed", largeText: true)
        revealText(app, element(app, "gateway.deletion.completed"))
        attach(app, "deletion-large-text-top")
        let notice = element(app, "gateway.deletion.appleManual")
        revealText(app, notice)
        XCTAssertLessThanOrEqual(notice.frame.maxX, app.windows.firstMatch.frame.maxX + 1)
        XCTAssertGreaterThanOrEqual(notice.frame.minX, 0)
        XCTAssertFalse(app.buttons["gateway.deletion.continue"].exists)
        attach(app, "deletion-large-text-manual")
    }

    func testUnconfiguredNativeGatewayDoesNotOfferADeletionOrSignInFallback() {
        let app = XCUIApplication()
        app.launchEnvironment["ECHOES_GATEWAY_AUTH_CHECK"] = "1"
        app.launch()
        XCTAssertTrue(element(app, "gateway.auth.unconfigured").waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["gateway.auth.signIn"].exists)
        XCTAssertFalse(app.buttons["gateway.auth.deletion"].exists)
        attach(app, "deletion-native-unconfigured")
    }
    func testConfirmActionSurvivesAlertDismissalAndReportsThePreviewAuthorizerFailure() {
        let app = application("recovery")
        let recovery = app.buttons["gateway.deletion.recoverSaved"]
        reveal(app, recovery)
        recovery.tap()
        let confirm = app.buttons["gateway.deletion.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(element(app, "gateway.deletion.error").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "gateway.deletion.completed").exists)
        attach(app, "deletion-confirmation-error")
    }

    func testCompletedReceiptCanBeRemovedLocallyOnlyAfterItsOwnConfirmation() {
        let app = application("completed")
        let remove = app.buttons["gateway.deletion.forget"]
        reveal(app, remove)
        remove.tap()
        let cancel = app.buttons["gateway.deletion.cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Usuń potwierdzenie"].exists)
        XCTAssertFalse(app.buttons["Potwierdź przez Apple"].exists)
        attach(app, "deletion-forget-confirmation")
        cancel.tap()
        XCTAssertTrue(element(app, "gateway.deletion.completed").exists)
        reveal(app, remove)
        remove.tap()
        app.buttons["gateway.deletion.confirm"].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["Brak zapisanych żądań na tym urządzeniu."].waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "gateway.deletion.completed").exists)
        XCTAssertFalse(remove.exists)
        XCTAssertFalse(element(app, "gateway.deletion.error").exists)
        attach(app, "deletion-forget-empty")
    }

}
