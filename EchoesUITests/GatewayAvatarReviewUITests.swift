import XCTest

/// Real moderator view/host/journal/codec with synthetic disk storage, identities and HTTP provider.
@MainActor final class GatewayAvatarReviewUITests: XCTestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func application(_ mode: String = "normal", large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ECHOES_AVATAR_REVIEW_UI_PREVIEW"] = mode
        app.launchEnvironment["ECHOES_AVATAR_REVIEW_UI_RUN"] = UUID().uuidString.lowercased()
        if large {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        }
        app.launch()
        XCTAssertTrue(element(app, "avatar.review.previewNotice").waitForExistence(timeout: 15))
        XCTAssertTrue(element(app, "avatar.review").exists)
        attach(app, "moderator-" + mode + "-initial")
        return app
    }
    private func tap(_ app: XCUIApplication, _ id: String) {
        let button = app.buttons[id]
        for _ in 0..<9 where !button.exists || !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.isHittable, String(app.debugDescription.suffix(5000)))
        wait(button, "enabled == true")
        button.tap()
    }
    private func reveal(_ app: XCUIApplication, _ id: String, fully: Bool = false) -> XCUIElement {
        let target = element(app, id)
        for _ in 0..<16 {
            let title = app.navigationBars["Potwierdzenie"].exists ? "Potwierdzenie" : "Ocena zdjęć"
            let top = app.navigationBars[title].frame.maxY + 8
            let bottom = element(app, "avatar.review.fixture.count").frame.minY - 8
            if target.exists, target.isHittable,
                !fully || target.frame.minY >= top && target.frame.maxY <= bottom
            {
                return target
            }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let up = !target.exists || target.frame.maxY > bottom
            origin.withOffset(.init(dx: app.frame.width / 2, dy: up ? bottom - 20 : top + 20)).press(
                forDuration: 0.03,
                thenDragTo: origin.withOffset(
                    .init(dx: app.frame.width / 2, dy: up ? top + 20 : bottom - 20)),
                withVelocity: XCUIGestureVelocity(rawValue: 1500), thenHoldForDuration: 0)
        }
        XCTFail("Element is not reachable: " + id)
        return target
    }
    private func wait(_ value: XCUIElement, _ predicate: String, timeout: TimeInterval = 12) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: value)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: timeout), .completed)
    }
    private func image(_ app: XCUIApplication) {
        tap(app, "avatar.review.item.0")
        let preview = element(app, "avatar.review.image")
        for _ in 0..<6 where !preview.exists || !preview.isHittable { app.swipeDown() }
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertTrue(preview.isHittable)
    }
    private func decide(_ app: XCUIApplication, approve: Bool = true) {
        tap(app, approve ? "avatar.review.approve" : "avatar.review.reject")
        let label = approve ? "Potwierdź zatwierdzenie" : "Potwierdź odrzucenie"
        let confirm = app.alerts.buttons[label].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        attach(app, approve ? "moderator-confirm-approval" : "moderator-confirm-rejection")
        confirm.tap()
    }
    private func count(_ app: XCUIApplication, _ count: Int) {
        let value = element(app, "avatar.review.fixture.count")
        wait(value, "label CONTAINS 'Decyzje: \(count)' AND label CONTAINS 'Wylogowania: 0'")
    }
    private func outcome(_ app: XCUIApplication, contains: String) {
        let value = element(app, "avatar.review.outcome")
        wait(value, "label CONTAINS '\(contains)'")
    }
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testApprovalRequiresRenderedImageAndExplicitConfirmation() {
        let app = application()
        XCTAssertFalse(app.buttons["avatar.review.approve"].exists)
        image(app)
        tap(app, "avatar.review.approve")
        XCTAssertTrue(app.alerts.buttons["Potwierdź zatwierdzenie"].firstMatch.waitForExistence(timeout: 5))
        attach(app, "moderator-cancellable-approval-alert")
        app.alerts.buttons["Anuluj"].firstMatch.tap()
        count(app, 0)
        attach(app, "moderator-current-image-before-decision")
        decide(app)
        outcome(app, contains: "Zatwierdzenie")
        count(app, 1)
        XCTAssertFalse(element(app, "avatar.review.image").exists)
        attach(app, "moderator-approved-without-publication")
    }
    func testRejectionAndAcknowledgementClearOnlyTheResolvedIntent() {
        let app = application()
        image(app)
        decide(app, approve: false)
        outcome(app, contains: "Odrzucenie")
        count(app, 1)
        tap(app, "avatar.review.acknowledge")
        XCTAssertTrue(app.buttons["avatar.review.refresh"].waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "avatar.review.outcome").exists)
        tap(app, "avatar.review.refresh")
        XCTAssertTrue(element(app, "avatar.review.empty").waitForExistence(timeout: 5))
        count(app, 1)
    }
    func testLostReplySurvivesRealProcessRestartAndRecoveryDoesNotResendDecision() {
        let app = application("lost")
        image(app)
        decide(app)
        XCTAssertTrue(element(app, "avatar.review.unknown").waitForExistence(timeout: 10))
        count(app, 1)
        attach(app, "moderator-unknown-before-restart")
        app.terminate()
        app.launch()
        XCTAssertTrue(element(app, "avatar.review.unknown").waitForExistence(timeout: 15))
        XCTAssertFalse(element(app, "avatar.review.image").exists)
        count(app, 1)
        tap(app, "avatar.review.recover")
        outcome(app, contains: "Zatwierdzenie")
        count(app, 1)
        attach(app, "moderator-recovered-after-process-restart")
    }
    func testNotAppliedNeedsExplicitCancelableClosureBeforeAcknowledgementAndFreshInspection() {
        let app = application("not-applied")
        image(app)
        decide(app)
        XCTAssertTrue(element(app, "avatar.review.unknown").waitForExistence(timeout: 10))
        tap(app, "avatar.review.recover")
        outcome(app, contains: "nie jest potwierdzona")
        XCTAssertFalse(app.buttons["avatar.review.acknowledge"].exists)
        tap(app, "avatar.review.retire")
        XCTAssertTrue(element(app, "avatar.review.retireConfirmation").waitForExistence(timeout: 5))
        attach(app, "upload-review-retirement-confirmation")
        reveal(app, "avatar.review.retireCancel").tap()
        wait(element(app, "avatar.review.fixture.count"), "value CONTAINS 'Zamknięcia: 0'")
        tap(app, "avatar.review.retire")
        reveal(app, "avatar.review.retireConfirm", fully: true).tap()
        outcome(app, contains: "próba została zamknięta")
        wait(element(app, "avatar.review.fixture.count"), "value CONTAINS 'Zamknięcia: 1'")
        attach(app, "upload-review-retired-no-undo-or-publication")
        XCTAssertFalse(app.buttons["avatar.review.item.0"].exists)
        count(app, 1)
        attach(app, "moderator-not-applied")
        tap(app, "avatar.review.acknowledge")
        tap(app, "avatar.review.refresh")
        image(app)
        count(app, 1)
    }
    func testLostClosureReplySurvivesProcessRestartAndRecoveryNeverResends() {
        let app = application("retire-lost")
        image(app)
        decide(app)
        XCTAssertTrue(element(app, "avatar.review.unknown").waitForExistence(timeout: 10))
        tap(app, "avatar.review.retire")
        reveal(app, "avatar.review.retireConfirm", fully: true).tap()
        wait(element(app, "avatar.review.fixture.count"), "value CONTAINS 'Zamknięcia: 1'")
        wait(element(app, "avatar.review.unknown"), "label CONTAINS 'potwierdzenie zamknięcia'")
        XCTAssertFalse(app.buttons["avatar.review.acknowledge"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(element(app, "avatar.review.unknown").waitForExistence(timeout: 15))
        count(app, 1)
        attach(app, "upload-review-retiring-after-process-restart")
        tap(app, "avatar.review.recover")
        outcome(app, contains: "próba została zamknięta")
        wait(element(app, "avatar.review.fixture.count"), "value CONTAINS 'Zamknięcia: 1'")
        app.terminate()
        app.launch()
        outcome(app, contains: "próba została zamknięta")
        tap(app, "avatar.review.acknowledge")
        count(app, 1)
    }
    func testClosureConfirmationLargestTextAndBackgroundCannotDispatch() {
        let app = application("not-applied", large: true)
        image(app)
        decide(app)
        XCTAssertTrue(reveal(app, "avatar.review.unknown").exists)
        tap(app, "avatar.review.retire")
        XCTAssertTrue(element(app, "avatar.review.retireConfirmation").waitForExistence(timeout: 5))
        let confirm = reveal(app, "avatar.review.retireConfirm", fully: true)
        XCTAssertTrue(confirm.isEnabled)
        attach(app, "upload-review-retirement-largest-text")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(reveal(app, "avatar.review.closed").exists)
        XCTAssertFalse(app.buttons["avatar.review.retireConfirm"].exists)
        attach(app, "upload-review-background-closed-largest-text")
        tap(app, "avatar.review.reconnect")
        XCTAssertTrue(reveal(app, "avatar.review.unknown").exists)
        wait(element(app, "avatar.review.fixture.count"), "value CONTAINS 'Zamknięcia: 0'")
        count(app, 1)
    }
    func testSupersededDoesNotClaimHistoricalSuccessOrFailure() {
        let app = application("superseded")
        image(app)
        decide(app)
        XCTAssertTrue(element(app, "avatar.review.unknown").waitForExistence(timeout: 10))
        tap(app, "avatar.review.recover")
        outcome(app, contains: "Nie możemy potwierdzić")
        count(app, 1)
        attach(app, "moderator-superseded-warning")
        tap(app, "avatar.review.acknowledge")
        XCTAssertFalse(element(app, "avatar.review.outcome").exists)
    }
    func testExpiryClosesPendingConfirmationAndRequiresNewImage() {
        let app = application("expiry")
        image(app)
        tap(app, "avatar.review.approve")
        XCTAssertTrue(app.alerts.buttons["Potwierdź zatwierdzenie"].firstMatch.waitForExistence(timeout: 5))
        wait(app.alerts.buttons["Potwierdź zatwierdzenie"].firstMatch, "exists == false", timeout: 22)
        XCTAssertTrue(element(app, "avatar.review.expired").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "avatar.review.image").exists)
        count(app, 0)
        attach(app, "moderator-expired-confirmation")
        tap(app, "avatar.review.reloadImage")
        XCTAssertTrue(element(app, "avatar.review.image").waitForExistence(timeout: 5))
    }
    func testLateInspectionCannotRestoreImageAfterSwitchingNativeAccount() {
        let app = application("delayed")
        tap(app, "avatar.review.item.0")
        XCTAssertTrue(element(app, "avatar.review.busy").waitForExistence(timeout: 5))
        tap(app, "avatar.review.fixture.menu")
        app.buttons["Zmień konto testowe"].tap()
        tap(app, "avatar.review.fixture.menu")
        app.buttons["Zwolnij odpowiedź"].tap()
        XCTAssertTrue(element(app, "avatar.review.closed").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "avatar.review.image").exists)
        count(app, 0)
        tap(app, "avatar.review.reconnect")
        image(app)
        count(app, 0)
    }
    func testBackgroundDropsImageAndRestoresPendingIntentOnlyAfterExplicitReopen() {
        let app = application("lost")
        image(app)
        decide(app)
        XCTAssertTrue(element(app, "avatar.review.unknown").waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(element(app, "avatar.review.closed").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "avatar.review.image").exists)
        count(app, 1)
        tap(app, "avatar.review.reconnect")
        XCTAssertTrue(element(app, "avatar.review.unknown").waitForExistence(timeout: 10))
        tap(app, "avatar.review.recover")
        outcome(app, contains: "Zatwierdzenie")
        count(app, 1)
    }
    func testLargestTextKeepsImageDecisionAndOutcomeReachable() {
        let app = application(large: true)
        image(app)
        attach(app, "moderator-largest-text-preview")
        decide(app, approve: false)
        outcome(app, contains: "Odrzucenie")
        tap(app, "avatar.review.acknowledge")
        count(app, 1)
        attach(app, "moderator-largest-text-acknowledged")
    }
    func testEmptyAndDeniedStatesDoNotSignOutOrExposeImages() {
        for mode in ["empty", "denied"] {
            let app = application(mode)
            XCTAssertTrue(
                element(app, mode == "empty" ? "avatar.review.empty" : "avatar.review.denied")
                    .waitForExistence(timeout: 10))
            XCTAssertFalse(element(app, "avatar.review.image").exists)
            XCTAssertFalse(app.buttons["avatar.review.approve"].exists)
            count(app, 0)
            attach(app, "moderator-" + mode + "-state")
            app.terminate()
        }
    }
}
