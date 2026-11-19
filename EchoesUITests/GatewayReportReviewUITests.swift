import XCTest

/// Real view/host/journal/client, synthetic identity/provider, isolated disk state for restart tests.
@MainActor final class GatewayReportReviewUITests: XCTestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func application(_ mode: String = "normal", large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ECHOES_REPORT_REVIEW_UI_PREVIEW"] = mode
        app.launchEnvironment["ECHOES_REPORT_REVIEW_UI_RUN"] = UUID().uuidString.lowercased()
        if large {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        }
        app.launch()
        XCTAssertTrue(element(app, "report.review.previewNotice").waitForExistence(timeout: 15))
        return app
    }
    private func wait(_ target: XCUIElement, _ format: String, timeout: TimeInterval = 10) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }
    private func scroll(
        _ app: XCUIApplication, up: Bool, confirmation: Bool = false, toward target: XCUIElement? = nil
    ) {
        let top = app.navigationBars[confirmation ? "Potwierdzenie" : "Zgłoszenia"].frame.maxY + 8
        let lower =
            confirmation
            ? app.buttons["report.review.confirm"].frame.minY
            : element(app, "report.review.fixture.count").frame.minY
        let bottom = min(lower - 8, element(app, "report.review.fixture.count").frame.minY - 8)
        guard bottom > top + 50 else {
            XCTFail("No visible scroll viewport")
            return
        }
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let x = app.frame.midX - app.frame.minX
        let center = (top + bottom) / 2
        let delta = target.flatMap { $0.exists ? abs($0.frame.midY - center) : nil }
        let distance = min((bottom - top) * 0.9, max(60, (delta ?? bottom - top) * 0.7))
        let high = center - distance / 2
        let low = center + distance / 2
        let velocity: XCUIGestureVelocity =
            (delta ?? .infinity) < bottom - top
            ? .slow : XCUIGestureVelocity(rawValue: 2000)
        origin.withOffset(.init(dx: x, dy: up ? low : high)).press(
            forDuration: 0.03, thenDragTo: origin.withOffset(.init(dx: x, dy: up ? high : low)),
            withVelocity: velocity, thenHoldForDuration: 0)
    }
    private func visible(_ app: XCUIApplication, _ id: String, confirmation: Bool = false) -> XCUIElement {
        let target = element(app, id)
        for _ in 0..<16 {
            if target.exists && target.isHittable { return target }
            let top = app.navigationBars[confirmation ? "Potwierdzenie" : "Zgłoszenia"].frame.maxY
            scroll(
                app, up: !target.exists || target.frame.midY > top, confirmation: confirmation,
                toward: target)
        }
        XCTAssertTrue(target.isHittable, String(app.debugDescription.suffix(6000)))
        return target
    }
    private func tap(_ app: XCUIApplication, _ id: String, confirmation: Bool = false) {
        visible(app, id, confirmation: confirmation).tap()
    }
    private func count(_ app: XCUIApplication, _ value: Int) {
        wait(
            element(app, "report.review.fixture.count"),
            "label CONTAINS 'Decyzje: \(value)' AND label CONTAINS 'Wylogowania: 0'")
    }
    private func openItem(_ app: XCUIApplication) {
        tap(app, "report.review.item.0")
        XCTAssertTrue(element(app, "report.review.reason").waitForExistence(timeout: 10))
    }
    private func reachEnd(_ app: XCUIApplication, confirmation: Bool = false) {
        let prefix = confirmation ? "report.review.confirmation" : "report.review"
        let end = element(app, prefix + ".end")
        for _ in 0..<20 {
            let top = app.navigationBars[confirmation ? "Potwierdzenie" : "Zgłoszenia"].frame.maxY + 8
            let bottom =
                min(
                    confirmation ? app.buttons["report.review.confirm"].frame.minY : app.frame.maxY,
                    element(app, "report.review.fixture.count").frame.minY) - 8
            if end.exists && end.frame.height > 0 && end.frame.minY >= top && end.frame.maxY <= bottom {
                break
            }
            scroll(
                app, up: !end.exists || end.frame.midY > (top + bottom) / 2,
                confirmation: confirmation, toward: end)
        }
        let top = app.navigationBars[confirmation ? "Potwierdzenie" : "Zgłoszenia"].frame.maxY
        let bottom = element(app, "report.review.fixture.count").frame.minY
        XCTAssertTrue(end.exists && end.frame.height > 0 && end.frame.minY >= top && end.frame.maxY <= bottom)
        if !confirmation {
            wait(visible(app, "report.review.dismiss"), "enabled == true")
        }
    }
    private func choose(_ app: XCUIApplication, hide: Bool = true) {
        reachEnd(app)
        tap(app, hide ? "report.review.hide" : "report.review.dismiss")
        XCTAssertTrue(element(app, "report.review.confirmationContent").waitForExistence(timeout: 5))
    }
    private func confirm(_ app: XCUIApplication) {
        reachEnd(app, confirmation: true)
        wait(app.buttons["report.review.confirm"], "enabled == true")
        XCTAssertTrue(app.buttons["report.review.confirm"].isHittable)
        app.buttons["report.review.confirm"].tap()
    }
    private func outcome(_ app: XCUIApplication, contains: String) {
        let target = visible(app, "report.review.outcome")
        wait(target, "label CONTAINS '\(contains)'")
    }
    private func attach(_ app: XCUIApplication, _ name: String) {
        let value = XCTAttachment(screenshot: app.screenshot())
        value.name = name
        value.lifetime = .keepAlways
        add(value)
    }

    func testHideRequiresMaterialAndSeparateCancelableConfirmation() {
        let app = application()
        XCTAssertFalse(app.buttons["report.review.hide"].exists)
        openItem(app)
        XCTAssertTrue(element(app, "report.review.message").exists)
        choose(app)
        count(app, 0)
        attach(app, "report-confirmation-before-decision")
        app.buttons["report.review.confirmCancel"].tap()
        count(app, 0)
        choose(app)
        confirm(app)
        outcome(app, contains: "Ukrycie wiadomości")
        count(app, 1)
        XCTAssertFalse(element(app, "report.review.message").exists)
        attach(app, "report-hidden-confirmed")
    }
    func testDismissAndAcknowledgementCloseOnlyResolvedReport() {
        let app = application()
        openItem(app)
        choose(app, hide: false)
        confirm(app)
        outcome(app, contains: "Odrzucenie zgłoszenia")
        count(app, 1)
        tap(app, "report.review.acknowledge")
        tap(app, "report.review.refresh")
        XCTAssertTrue(element(app, "report.review.empty").waitForExistence(timeout: 10))
        count(app, 1)
    }
    func testLostACKSurvivesRealProcessRestartAndRecoveryDoesNotResend() {
        let app = application("lost")
        openItem(app)
        choose(app)
        confirm(app)
        XCTAssertTrue(element(app, "report.review.unknown").waitForExistence(timeout: 10))
        count(app, 1)
        attach(app, "report-unknown-before-restart")
        app.terminate()
        app.launch()
        XCTAssertTrue(element(app, "report.review.unknown").waitForExistence(timeout: 15))
        XCTAssertFalse(element(app, "report.review.message").exists)
        count(app, 1)
        tap(app, "report.review.recover")
        outcome(app, contains: "Ukrycie wiadomości")
        count(app, 1)
        attach(app, "report-recovered-after-process-restart")
    }
    func testNotAppliedNeedsAcknowledgementAndNewInspection() {
        let app = application("not-applied")
        openItem(app)
        choose(app)
        confirm(app)
        XCTAssertTrue(element(app, "report.review.unknown").waitForExistence(timeout: 10))
        tap(app, "report.review.recover")
        outcome(app, contains: "nie została zastosowana")
        count(app, 1)
        XCTAssertFalse(app.buttons["report.review.item.0"].exists)
        tap(app, "report.review.acknowledge")
        tap(app, "report.review.refresh")
        openItem(app)
        count(app, 1)
    }
    func testSupersededDoesNotClaimSuccessAndCannotRestoreOldMaterial() {
        let app = application("superseded")
        openItem(app)
        choose(app)
        confirm(app)
        XCTAssertTrue(element(app, "report.review.unknown").waitForExistence(timeout: 10))
        tap(app, "report.review.recover")
        outcome(app, contains: "Nie możemy potwierdzić")
        count(app, 1)
        XCTAssertFalse(element(app, "report.review.message").exists)
        attach(app, "report-superseded")
    }
    func testMissingMessageAllowsOnlyDismissal() {
        let app = application("missing")
        openItem(app)
        XCTAssertTrue(element(app, "report.review.missingMessage").exists)
        reachEnd(app)
        XCTAssertFalse(app.buttons["report.review.hide"].isEnabled)
        choose(app, hide: false)
        confirm(app)
        outcome(app, contains: "Odrzucenie zgłoszenia")
        count(app, 1)
        attach(app, "report-missing-message-dismissed")
    }
    func testExpiryClosesConfirmationAndRequiresFreshMaterial() {
        let app = application("expiry")
        openItem(app)
        choose(app)
        wait(element(app, "report.review.confirmationContent"), "exists == false", timeout: 22)
        XCTAssertTrue(element(app, "report.review.expired").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "report.review.message").exists)
        count(app, 0)
        attach(app, "report-expired-confirmation")
        tap(app, "report.review.reload")
        XCTAssertTrue(element(app, "report.review.message").waitForExistence(timeout: 10))
        count(app, 0)
    }
    func testBackgroundDropsMaterialAndRequiresExplicitReopen() {
        let app = application()
        openItem(app)
        choose(app)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(element(app, "report.review.closed").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "report.review.message").exists)
        XCTAssertFalse(element(app, "report.review.confirmationContent").exists)
        count(app, 0)
        tap(app, "report.review.reconnect")
        openItem(app)
        count(app, 0)
    }
    func testLateResponseCannotShowMaterialAfterNativeAccountChange() {
        let app = application("delayed")
        tap(app, "report.review.item.0")
        XCTAssertTrue(element(app, "report.review.busy").waitForExistence(timeout: 5))
        app.buttons["report.review.fixture.menu"].tap()
        app.buttons["Zmień konto testowe"].tap()
        app.buttons["report.review.fixture.menu"].tap()
        app.buttons["Zwolnij odpowiedź"].tap()
        XCTAssertTrue(element(app, "report.review.closed").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "report.review.message").exists)
        count(app, 0)
        tap(app, "report.review.reconnect")
        openItem(app)
        count(app, 0)
    }
    func testPaginationReplacesPageAndPassesEmptyPageWithProgress() {
        let app = application("pages")
        tap(app, "report.review.next")
        wait(element(app, "report.review.page"), "label == 'Strona 2'")
        XCTAssertTrue(element(app, "report.review.empty").exists)
        XCTAssertFalse(app.buttons["report.review.item.0"].exists)
        tap(app, "report.review.next")
        wait(element(app, "report.review.page"), "label == 'Strona 3'")
        XCTAssertFalse(app.buttons["report.review.next"].exists)
        openItem(app)
        count(app, 0)
    }
    func testEmptyDeniedAndFailedReadNeverClaimMaterialOrSignOut() {
        for (mode, id) in [
            ("empty", "report.review.empty"), ("denied", "report.review.denied"),
            ("unavailable", "report.review.error"),
        ] {
            let app = application(mode)
            XCTAssertTrue(element(app, id).waitForExistence(timeout: 10))
            XCTAssertFalse(element(app, "report.review.message").exists)
            XCTAssertFalse(app.buttons["report.review.item.0"].exists)
            count(app, 0)
            if mode == "unavailable" { XCTAssertFalse(element(app, "report.review.empty").exists) }
            attach(app, "report-state-" + mode)
            app.terminate()
        }
    }
    func testLongestMaterialAndConfirmationRemainReachableAtLargestText() {
        let app = application("long", large: true)
        openItem(app)
        wait(
            element(app, "report.review.displayStatus"),
            "label == 'Przewiń do końca treści, aby wybrać decyzję.'")
        count(app, 0)
        attach(app, "report-largest-text-before-end")
        choose(app)
        XCTAssertFalse(app.buttons["report.review.confirm"].isEnabled)
        reachEnd(app, confirmation: true)
        wait(app.buttons["report.review.confirm"], "enabled == true")
        XCTAssertTrue(
            app.buttons["report.review.confirm"].isHittable
                && app.buttons["report.review.confirmCancel"].isHittable)
        attach(app, "report-largest-text-confirmation-end")
        app.buttons["report.review.confirm"].tap()
        outcome(app, contains: "Ukrycie wiadomości")
        count(app, 1)
        attach(app, "report-largest-text-outcome")
    }
}
