import XCTest

/// Real view/host/journal/client, synthetic identity/provider, isolated disk state for restart tests.
@MainActor final class GatewayAvatarReportReviewUITests: XCTestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func application(_ mode: String = "normal", large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ECHOES_AVATAR_REPORT_REVIEW_UI_PREVIEW"] = mode
        app.launchEnvironment["ECHOES_AVATAR_REPORT_REVIEW_UI_RUN"] = UUID().uuidString.lowercased()
        if large {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        }
        app.launch()
        XCTAssertTrue(element(app, "avatar.report.review.previewNotice").waitForExistence(timeout: 15))
        XCTAssertTrue(element(app, "avatar.report.review.form").exists)
        return app
    }
    private func wait(_ target: XCUIElement, _ format: String, timeout: TimeInterval = 10) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }
    private func scroll(
        _ app: XCUIApplication, up: Bool, confirmation: Bool = false, toward target: XCUIElement? = nil,
        precise: Bool = false
    ) {
        let title = app.navigationBars["Potwierdzenie"].exists ? "Potwierdzenie" : "Zgłoszenia zdjęć"
        let top = app.navigationBars[title].frame.maxY + 8
        var bottom = element(app, "avatar.report.review.fixture.count").frame.minY - 8
        let action = app.buttons["avatar.report.review.confirm"]
        if confirmation, action.exists, action.frame.height > 0,
            action.frame.minY > top + 80, action.frame.minY < bottom
        {
            bottom = action.frame.minY - 8
        }
        guard bottom > top + 50 else {
            XCTFail("No visible scroll viewport")
            return
        }
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let x = app.frame.midX - app.frame.minX
        let center = (top + bottom) / 2
        let delta = target.flatMap { $0.exists ? abs($0.frame.midY - center) : nil }
        let distance = min(
            precise ? 320 : .infinity, (bottom - top) * 0.9, max(60, (delta ?? bottom - top) * 0.7))
        let high = center - distance / 2
        let low = center + distance / 2
        let velocity: XCUIGestureVelocity =
            precise
            ? XCUIGestureVelocity(rawValue: 1000)
            : (delta ?? .infinity) < bottom - top
                ? .slow : XCUIGestureVelocity(rawValue: 2000)
        origin.withOffset(.init(dx: x, dy: up ? low : high)).press(
            forDuration: 0.03, thenDragTo: origin.withOffset(.init(dx: x, dy: up ? high : low)),
            withVelocity: velocity, thenHoldForDuration: precise ? 0.2 : 0)
    }
    private func visible(_ app: XCUIApplication, _ id: String, confirmation: Bool = false) -> XCUIElement {
        let target = element(app, id)
        for _ in 0..<16 {
            if target.exists && target.isHittable { return target }
            let title = app.navigationBars["Potwierdzenie"].exists ? "Potwierdzenie" : "Zgłoszenia zdjęć"
            let top = app.navigationBars[title].frame.maxY
            scroll(
                app, up: !target.exists || target.frame.midY > top, confirmation: confirmation,
                toward: target)
        }
        XCTAssertTrue(target.isHittable, String(app.debugDescription.suffix(6000)))
        return target
    }
    private func fullyVisibleButton(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let target = app.buttons[id]
        for _ in 0..<16 {
            let title = app.navigationBars["Potwierdzenie"].exists ? "Potwierdzenie" : "Zgłoszenia zdjęć"
            let top = app.navigationBars[title].frame.maxY + 8
            let bottom = element(app, "avatar.report.review.fixture.count").frame.minY - 8
            if target.exists, target.isHittable, target.frame.minY >= top, target.frame.maxY <= bottom {
                return target
            }
            scroll(app, up: !target.exists || target.frame.maxY > bottom, toward: target)
        }
        XCTFail("Button is not fully visible: " + id)
        return target
    }
    private func tap(_ app: XCUIApplication, _ id: String, confirmation: Bool = false) {
        visible(app, id, confirmation: confirmation).tap()
    }
    private func count(_ app: XCUIApplication, _ value: Int) {
        wait(
            element(app, "avatar.report.review.fixture.count"),
            "label CONTAINS 'Decyzje: \(value)' AND label CONTAINS 'Wylogowania: 0'")
    }
    private func openItem(_ app: XCUIApplication) {
        tap(app, "avatar.report.review.item.0")
        XCTAssertTrue(element(app, "avatar.report.review.reason").waitForExistence(timeout: 10))
    }
    private func reachImage(_ app: XCUIApplication, confirmation: Bool = false) {
        let prefix = confirmation ? "avatar.report.review.confirmation" : "avatar.report.review"
        if element(app, prefix + ".missingPhoto").exists { return }
        let image = element(app, prefix + ".image")
        for _ in 0..<20 {
            let title = app.navigationBars["Potwierdzenie"].exists ? "Potwierdzenie" : "Zgłoszenia zdjęć"
            let top = app.navigationBars[title].frame.maxY + 8
            let bottom = element(app, "avatar.report.review.fixture.count").frame.minY - 8
            if image.exists, image.frame.height > 0, image.frame.width > 0,
                image.frame.minY >= top, image.frame.maxY <= bottom
            {
                return
            }
            scroll(
                app, up: !image.exists || image.frame.maxY > bottom,
                confirmation: confirmation, toward: image)
        }
        XCTFail(
            "The actual image was not fully visible before reading the reason: "
                + String(app.debugDescription.suffix(6000)))
    }
    private func reachEnd(_ app: XCUIApplication, confirmation: Bool = false) {
        reachImage(app, confirmation: confirmation)
        let prefix = confirmation ? "avatar.report.review.confirmation" : "avatar.report.review"
        let end = element(app, prefix + ".end")
        for _ in 0..<20 {
            let top = app.navigationBars[confirmation ? "Potwierdzenie" : "Zgłoszenia zdjęć"].frame.maxY + 8
            let bottom = element(app, "avatar.report.review.fixture.count").frame.minY - 8
            if end.exists, end.frame.height > 0, end.frame.minY >= top, end.frame.maxY <= bottom {
                // The acknowledgement changes the status row height at AX sizes. Re-query after it
                // settles, rather than using a frame captured before the layout change.
                if !confirmation { wait(app.buttons["avatar.report.review.dismiss"], "enabled == true") }
                if end.exists, end.frame.minY >= top, end.frame.maxY <= bottom { break }
            }
            let up: Bool
            if end.exists, end.frame.height > 0 {
                up = end.frame.midY > (top + bottom) / 2
            } else {
                // Form can recycle the end marker and both decision buttons after an overshoot.
                // A visible following action or queue row locates us below the material.
                let followingIDs =
                    confirmation
                    ? ["avatar.report.review.confirm", "avatar.report.review.confirmCancel"]
                    : [
                        "avatar.report.review.dismiss", "avatar.report.review.hide",
                        "avatar.report.review.page",
                        "avatar.report.review.refresh",
                    ]
                up = !followingIDs.contains { id in
                    let following = element(app, id)
                    return following.exists && following.frame.height > 0
                        && following.frame.maxY > top && following.frame.minY < bottom
                }
            }
            scroll(app, up: up, confirmation: confirmation, toward: end, precise: true)
        }
        let top = app.navigationBars[confirmation ? "Potwierdzenie" : "Zgłoszenia zdjęć"].frame.maxY
        let bottom = element(app, "avatar.report.review.fixture.count").frame.minY
        XCTAssertTrue(
            end.exists && end.frame.height > 0 && end.frame.minY >= top && end.frame.maxY <= bottom,
            "The actual end marker must be fully visible: " + String(app.debugDescription.suffix(6000)))
        if !confirmation {
            wait(visible(app, "avatar.report.review.dismiss"), "enabled == true")
        }
    }
    private func choose(_ app: XCUIApplication, hide: Bool = true) {
        reachEnd(app)
        tap(app, hide ? "avatar.report.review.hide" : "avatar.report.review.dismiss")
        XCTAssertTrue(element(app, "avatar.report.review.confirmationContent").waitForExistence(timeout: 5))
    }
    private func confirm(_ app: XCUIApplication) {
        reachEnd(app, confirmation: true)
        wait(app.buttons["avatar.report.review.confirm"], "enabled == true")
        XCTAssertTrue(app.buttons["avatar.report.review.confirm"].isHittable)
        fullyVisibleButton(app, "avatar.report.review.confirm").tap()
    }
    private func outcome(_ app: XCUIApplication, contains: String) {
        let target = visible(app, "avatar.report.review.outcome")
        wait(target, "label CONTAINS '\(contains)'")
    }
    private func attach(_ app: XCUIApplication, _ name: String) {
        let value = XCTAttachment(screenshot: app.screenshot())
        value.name = "avatar-" + name
        value.lifetime = .keepAlways
        add(value)
    }

    func testHideRequiresMaterialAndSeparateCancelableConfirmation() {
        let app = application()
        XCTAssertFalse(app.buttons["avatar.report.review.hide"].exists)
        openItem(app)
        XCTAssertTrue(element(app, "avatar.report.review.image").exists)
        choose(app)
        count(app, 0)
        attach(app, "report-confirmation-before-decision")
        fullyVisibleButton(app, "avatar.report.review.confirmCancel").tap()
        count(app, 0)
        choose(app)
        confirm(app)
        outcome(app, contains: "Ukrycie zdjęcia")
        count(app, 1)
        XCTAssertFalse(element(app, "avatar.report.review.image").exists)
        attach(app, "report-hidden-confirmed")
    }
    func testDismissAndAcknowledgementCloseOnlyResolvedReport() {
        let app = application()
        openItem(app)
        choose(app, hide: false)
        confirm(app)
        outcome(app, contains: "Odrzucenie zgłoszenia")
        count(app, 1)
        tap(app, "avatar.report.review.acknowledge")
        tap(app, "avatar.report.review.refresh")
        XCTAssertTrue(element(app, "avatar.report.review.empty").waitForExistence(timeout: 10))
        count(app, 1)
    }
    func testLostACKSurvivesRealProcessRestartAndRecoveryDoesNotResend() {
        let app = application("lost")
        openItem(app)
        choose(app)
        confirm(app)
        XCTAssertTrue(element(app, "avatar.report.review.unknown").waitForExistence(timeout: 10))
        count(app, 1)
        attach(app, "report-unknown-before-restart")
        app.terminate()
        app.launch()
        XCTAssertTrue(element(app, "avatar.report.review.unknown").waitForExistence(timeout: 15))
        XCTAssertFalse(element(app, "avatar.report.review.image").exists)
        count(app, 1)
        tap(app, "avatar.report.review.recover")
        outcome(app, contains: "Ukrycie zdjęcia")
        count(app, 1)
        attach(app, "report-recovered-after-process-restart")
    }
    func testNotAppliedCannotBeAcknowledgedUntilExplicitCancelableServerClosure() {
        let app = application("not-applied")
        openItem(app)
        choose(app)
        confirm(app)
        XCTAssertTrue(element(app, "avatar.report.review.unknown").waitForExistence(timeout: 10))
        tap(app, "avatar.report.review.recover")
        outcome(app, contains: "nie jest potwierdzona")
        XCTAssertFalse(app.buttons["avatar.report.review.acknowledge"].exists)
        tap(app, "avatar.report.review.retire")
        XCTAssertTrue(element(app, "avatar.report.review.retireConfirmation").waitForExistence(timeout: 5))
        attach(app, "report-retirement-explicit-confirmation")
        tap(app, "avatar.report.review.retireCancel")
        wait(element(app, "avatar.report.review.fixture.count"), "value CONTAINS 'Zamknięcia: 0'")
        tap(app, "avatar.report.review.retire")
        tap(app, "avatar.report.review.retireConfirm")
        outcome(app, contains: "próba została zamknięta")
        wait(element(app, "avatar.report.review.fixture.count"), "value CONTAINS 'Zamknięcia: 1'")
        attach(app, "report-retired-no-undo-claim")
        count(app, 1)
        XCTAssertFalse(app.buttons["avatar.report.review.item.0"].exists)
        tap(app, "avatar.report.review.acknowledge")
        tap(app, "avatar.report.review.refresh")
        openItem(app)
        count(app, 1)
    }
    func testLostRetirementACKSurvivesProcessRestartAndReadOnlyRecovery() {
        let app = application("retire-lost")
        openItem(app)
        choose(app)
        confirm(app)
        XCTAssertTrue(element(app, "avatar.report.review.unknown").waitForExistence(timeout: 10))
        tap(app, "avatar.report.review.retire")
        tap(app, "avatar.report.review.retireConfirm")
        wait(element(app, "avatar.report.review.fixture.count"), "value CONTAINS 'Zamknięcia: 1'")
        wait(element(app, "avatar.report.review.unknown"), "label CONTAINS 'potwierdzenie zamknięcia'")
        XCTAssertFalse(app.buttons["avatar.report.review.acknowledge"].exists)
        app.terminate()
        app.launch()
        wait(element(app, "avatar.report.review.unknown"), "exists == true", timeout: 15)
        count(app, 1)
        attach(app, "report-retiring-after-process-restart")
        tap(app, "avatar.report.review.recover")
        outcome(app, contains: "próba została zamknięta")
        wait(element(app, "avatar.report.review.fixture.count"), "value CONTAINS 'Zamknięcia: 1'")
        count(app, 1)
        app.terminate()
        app.launch()
        outcome(app, contains: "próba została zamknięta")
        tap(app, "avatar.report.review.acknowledge")
        count(app, 1)
    }
    func testRetirementConfirmationAccessibilitySizeAndBackgroundCannotSend() {
        let app = application("not-applied", large: true)
        openItem(app)
        choose(app)
        confirm(app)
        XCTAssertTrue(element(app, "avatar.report.review.unknown").waitForExistence(timeout: 10))
        tap(app, "avatar.report.review.retire")
        XCTAssertTrue(element(app, "avatar.report.review.retireConfirmation").waitForExistence(timeout: 5))
        let confirm = fullyVisibleButton(app, "avatar.report.review.retireConfirm")
        XCTAssertTrue(confirm.isEnabled && confirm.isHittable)
        attach(app, "report-retirement-accessibility-size")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(visible(app, "avatar.report.review.closed").exists)
        XCTAssertFalse(app.buttons["avatar.report.review.retireConfirm"].exists)
        attach(app, "report-retirement-background-closed-large")
        tap(app, "avatar.report.review.reconnect")
        XCTAssertTrue(element(app, "avatar.report.review.unknown").waitForExistence(timeout: 10))
        wait(element(app, "avatar.report.review.fixture.count"), "value CONTAINS 'Zamknięcia: 0'")
        count(app, 1)
    }
    func testSupersededDoesNotClaimSuccessAndCannotRestoreOldMaterial() {
        let app = application("superseded")
        openItem(app)
        choose(app)
        confirm(app)
        XCTAssertTrue(element(app, "avatar.report.review.unknown").waitForExistence(timeout: 10))
        tap(app, "avatar.report.review.recover")
        outcome(app, contains: "Nie możemy potwierdzić")
        count(app, 1)
        XCTAssertFalse(element(app, "avatar.report.review.image").exists)
        attach(app, "report-superseded")
    }
    func testMissingPhotoAllowsOnlyDismissal() {
        let app = application("missing")
        openItem(app)
        XCTAssertTrue(element(app, "avatar.report.review.missingPhoto").exists)
        reachEnd(app)
        XCTAssertFalse(app.buttons["avatar.report.review.hide"].isEnabled)
        choose(app, hide: false)
        confirm(app)
        outcome(app, contains: "Odrzucenie zgłoszenia")
        count(app, 1)
        attach(app, "report-missing-photo-dismissed")
    }
    func testExpiryClosesConfirmationAndRequiresFreshMaterial() {
        let app = application("expiry")
        openItem(app)
        choose(app)
        wait(element(app, "avatar.report.review.confirmationContent"), "exists == false", timeout: 22)
        XCTAssertTrue(element(app, "avatar.report.review.expired").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "avatar.report.review.image").exists)
        count(app, 0)
        attach(app, "report-expired-confirmation")
        tap(app, "avatar.report.review.reload")
        XCTAssertTrue(element(app, "avatar.report.review.image").waitForExistence(timeout: 10))
        count(app, 0)
    }
    func testBackgroundDropsMaterialAndRequiresExplicitReopen() {
        let app = application()
        openItem(app)
        choose(app)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(element(app, "avatar.report.review.closed").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "avatar.report.review.image").exists)
        XCTAssertFalse(element(app, "avatar.report.review.confirmationContent").exists)
        count(app, 0)
        tap(app, "avatar.report.review.reconnect")
        openItem(app)
        count(app, 0)
    }
    func testLateResponseCannotShowMaterialAfterNativeAccountChange() {
        let app = application("delayed")
        tap(app, "avatar.report.review.item.0")
        XCTAssertTrue(element(app, "avatar.report.review.busy").waitForExistence(timeout: 5))
        app.buttons["avatar.report.review.fixture.menu"].tap()
        app.buttons["Zmień konto testowe"].tap()
        app.buttons["avatar.report.review.fixture.menu"].tap()
        app.buttons["Zwolnij odpowiedź"].tap()
        XCTAssertTrue(element(app, "avatar.report.review.closed").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "avatar.report.review.image").exists)
        count(app, 0)
        tap(app, "avatar.report.review.reconnect")
        openItem(app)
        count(app, 0)
    }
    func testPaginationReplacesPageAndPassesEmptyPageWithProgress() {
        let app = application("pages")
        tap(app, "avatar.report.review.next")
        wait(element(app, "avatar.report.review.page"), "label == 'Strona 2'")
        XCTAssertTrue(element(app, "avatar.report.review.empty").exists)
        XCTAssertFalse(app.buttons["avatar.report.review.item.0"].exists)
        tap(app, "avatar.report.review.next")
        wait(element(app, "avatar.report.review.page"), "label == 'Strona 3'")
        XCTAssertFalse(app.buttons["avatar.report.review.next"].exists)
        openItem(app)
        count(app, 0)
    }
    func testEmptyDeniedAndFailedReadNeverClaimMaterialOrSignOut() {
        for (mode, id) in [
            ("empty", "avatar.report.review.empty"), ("denied", "avatar.report.review.denied"),
            ("unavailable", "avatar.report.review.error"),
        ] {
            let app = application(mode)
            XCTAssertTrue(element(app, id).waitForExistence(timeout: 10))
            XCTAssertFalse(element(app, "avatar.report.review.image").exists)
            XCTAssertFalse(app.buttons["avatar.report.review.item.0"].exists)
            count(app, 0)
            if mode == "unavailable" { XCTAssertFalse(element(app, "avatar.report.review.empty").exists) }
            attach(app, "report-state-" + mode)
            app.terminate()
        }
    }
    func testLongestMaterialAndConfirmationRemainReachableAtLargestText() {
        let app = application("long", large: true)
        openItem(app)
        wait(
            element(app, "avatar.report.review.displayStatus"),
            "label == 'Obejrzyj zdjęcie i przewiń do końca opisu, aby wybrać decyzję.'")
        count(app, 0)
        attach(app, "report-largest-text-before-end")
        choose(app)
        XCTAssertFalse(app.buttons["avatar.report.review.confirm"].isEnabled)
        reachEnd(app, confirmation: true)
        wait(app.buttons["avatar.report.review.confirm"], "enabled == true")
        // After reaching the material end, actions may require further scrolling at AX XXXL.
        XCTAssertTrue(fullyVisibleButton(app, "avatar.report.review.confirmCancel").isEnabled)
        XCTAssertTrue(fullyVisibleButton(app, "avatar.report.review.confirm").isEnabled)
        attach(app, "report-largest-text-confirmation-end")
        fullyVisibleButton(app, "avatar.report.review.confirm").tap()
        outcome(app, contains: "Ukrycie zdjęcia")
        count(app, 1)
        attach(app, "report-largest-text-outcome")
    }
    func testDamagedFrameNeverShowsReasonOrImageAndCannotCreateDecision() {
        let app = application("damaged")
        tap(app, "avatar.report.review.item.0")
        let error = element(app, "avatar.report.review.error")
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertEqual(error.label, "Nie udało się odczytać zgłoszeń. Spróbuj ponownie.")
        XCTAssertFalse(element(app, "avatar.report.review.reason").exists)
        XCTAssertFalse(element(app, "avatar.report.review.image").exists)
        XCTAssertFalse(app.buttons["avatar.report.review.hide"].exists)
        XCTAssertFalse(app.buttons["avatar.report.review.dismiss"].exists)
        count(app, 0)
        attach(app, "report-damaged-frame-closed")
    }

}
